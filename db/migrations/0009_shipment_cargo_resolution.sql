-- =========================================================
-- 1. ACCOUNTING ACT NUMBER FOR WRITEOFF
-- =========================================================

ALTER TABLE shipment_cargo_movements
ADD COLUMN accounting_act_number TEXT;

ALTER TABLE shipment_cargo_movements
ADD CONSTRAINT shipment_cargo_movements_writeoff_act_check
CHECK (
    movement_type <> 'writeoff'
    OR (
        accounting_act_number IS NOT NULL
        AND length(trim(accounting_act_number)) > 0
    )
);


-- =========================================================
-- 2. RESOLVE SHIPMENT CARGO
-- =========================================================

CREATE OR REPLACE FUNCTION resolve_shipment_cargo(
    p_shipment_item_id UUID,
    p_movement_type TEXT,
    p_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason TEXT,
    p_return_storage_point_id UUID DEFAULT NULL,
    p_from_user_id UUID DEFAULT NULL,
    p_to_user_id UUID DEFAULT NULL,
    p_accounting_act_number TEXT DEFAULT NULL,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_inventory RECORD;

    v_loaded_quantity INTEGER;
    v_received_quantity INTEGER;
    v_resolved_quantity INTEGER;
    v_remaining_quantity INTEGER;

    v_quantity_before INTEGER;
    v_movement_id UUID;
BEGIN
    -- -----------------------------------------------------
    -- Basic validation
    -- -----------------------------------------------------

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Resolution quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'Resolution reason is required';
    END IF;

    IF p_movement_type NOT IN (
        'return',
        'loss',
        'writeoff',
        'responsibility_transfer'
    ) THEN
        RAISE EXCEPTION 'Invalid cargo resolution type';
    END IF;

    IF p_movement_type = 'return'
       AND p_return_storage_point_id IS NULL THEN
        RAISE EXCEPTION
            'Return storage point is required';
    END IF;

    IF p_movement_type = 'writeoff'
       AND (
           p_accounting_act_number IS NULL
           OR length(trim(p_accounting_act_number)) = 0
       ) THEN
        RAISE EXCEPTION
            'Accounting act number is required for writeoff';
    END IF;

    IF p_movement_type = 'responsibility_transfer'
       AND (
           p_from_user_id IS NULL
           OR p_to_user_id IS NULL
           OR p_from_user_id = p_to_user_id
       ) THEN
        RAISE EXCEPTION
            'Two different users are required for responsibility transfer';
    END IF;


    -- -----------------------------------------------------
    -- Idempotency
    -- -----------------------------------------------------

    SELECT id
    INTO v_movement_id
    FROM shipment_cargo_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_movement_id;
    END IF;


    -- -----------------------------------------------------
    -- Lock shipment item and shipment
    -- -----------------------------------------------------

    SELECT
        si.id,
        si.shipment_id,
        si.product_id,
        s.status AS shipment_status,
        s.source_storage_point_id,
        s.destination_storage_point_id,
        s.trip_id
    INTO v_item
    FROM shipment_items si
    JOIN shipments s
        ON s.id = si.shipment_id
    WHERE si.id = p_shipment_item_id
    FOR UPDATE OF si, s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shipment item not found';
    END IF;

    IF v_item.shipment_status IN ('cancelled', 'delivered') THEN
        RAISE EXCEPTION
            'Cargo cannot be resolved for this shipment status';
    END IF;


    -- -----------------------------------------------------
    -- Calculate unresolved cargo
    -- -----------------------------------------------------

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_loaded_quantity
    FROM shipment_loading_movements
    WHERE shipment_item_id = p_shipment_item_id;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_received_quantity
    FROM shipment_receipt_movements
    WHERE shipment_item_id = p_shipment_item_id;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_resolved_quantity
    FROM shipment_cargo_movements
    WHERE shipment_item_id = p_shipment_item_id;

    v_remaining_quantity :=
        v_loaded_quantity
        - v_received_quantity
        - v_resolved_quantity;

    IF p_quantity > v_remaining_quantity THEN
        RAISE EXCEPTION
            'Resolution exceeds unresolved cargo. Remaining: %, requested: %',
            v_remaining_quantity,
            p_quantity;
    END IF;


    -- -----------------------------------------------------
    -- Validate return destination
    -- -----------------------------------------------------

    IF p_movement_type = 'return' THEN

        IF NOT EXISTS (
            SELECT 1
            FROM storage_points
            WHERE id = p_return_storage_point_id
        ) THEN
            RAISE EXCEPTION 'Return storage point not found';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM storage_points
            WHERE id = p_return_storage_point_id
              AND status = 'closed'
        ) THEN
            RAISE EXCEPTION
                'Cargo cannot be returned to a closed storage point';
        END IF;

    END IF;


    -- -----------------------------------------------------
    -- Validate responsibility transfer
    -- -----------------------------------------------------

    IF p_movement_type = 'responsibility_transfer' THEN

        IF v_item.trip_id IS NULL THEN
            RAISE EXCEPTION
                'Shipment must belong to a trip for responsibility transfer';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE id = p_from_user_id
              AND is_active = TRUE
              AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION
                'Current responsible user is inactive or unavailable';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE id = p_to_user_id
              AND is_active = TRUE
              AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION
                'New responsible user is inactive or unavailable';
        END IF;

    END IF;


    -- -----------------------------------------------------
    -- Physical return
    -- -----------------------------------------------------

    IF p_movement_type = 'return' THEN

        INSERT INTO inventory (
            storage_point_id,
            product_id,
            quantity,
            reserved_quantity,
            blocked_quantity
        )
        VALUES (
            p_return_storage_point_id,
            v_item.product_id,
            0,
            0,
            0
        )
        ON CONFLICT (storage_point_id, product_id)
        DO NOTHING;

        SELECT *
        INTO v_inventory
        FROM inventory
        WHERE storage_point_id = p_return_storage_point_id
          AND product_id = v_item.product_id
        FOR UPDATE;

        v_quantity_before := v_inventory.quantity;

        UPDATE inventory
        SET
            quantity = quantity + p_quantity,
            updated_at = NOW()
        WHERE id = v_inventory.id;

        INSERT INTO inventory_movements (
            inventory_id,
            movement_type,
            quantity,
            quantity_before,
            quantity_after,
            reference_type,
            reference_id,
            reason,
            created_by
        )
        VALUES (
            v_inventory.id,
            'shipment_return',
            p_quantity,
            v_quantity_before,
            v_quantity_before + p_quantity,
            'shipment_item',
            p_shipment_item_id,
            p_reason,
            p_user_id
        );

    END IF;


    -- -----------------------------------------------------
    -- Record cargo resolution
    -- -----------------------------------------------------

    INSERT INTO shipment_cargo_movements (
        shipment_item_id,
        movement_type,
        quantity,
        operation_key,
        return_storage_point_id,
        from_user_id,
        to_user_id,
        reason,
        comment,
        accounting_act_number,
        created_by
    )
    VALUES (
        p_shipment_item_id,
        p_movement_type,
        p_quantity,
        p_operation_key,
        p_return_storage_point_id,
        p_from_user_id,
        p_to_user_id,
        p_reason,
        p_comment,
        p_accounting_act_number,
        p_user_id
    )
    RETURNING id
    INTO v_movement_id;


    -- -----------------------------------------------------
    -- Detailed trip responsibility history
    -- -----------------------------------------------------

    IF p_movement_type = 'responsibility_transfer' THEN

        INSERT INTO trip_responsibility_transfers (
            trip_id,
            shipment_item_id,
            quantity,
            from_user_id,
            to_user_id,
            reason,
            created_by
        )
        VALUES (
            v_item.trip_id,
            p_shipment_item_id,
            p_quantity,
            p_from_user_id,
            p_to_user_id,
            p_reason,
            p_user_id
        );

    END IF;


    -- -----------------------------------------------------
    -- Shipment event
    -- -----------------------------------------------------

    INSERT INTO shipment_events (
        shipment_id,
        event_type,
        description,
        metadata,
        created_by
    )
    VALUES (
        v_item.shipment_id,
        'cargo_' || p_movement_type,
        p_reason,
        jsonb_build_object(
            'shipment_item_id', p_shipment_item_id,
            'quantity', p_quantity,
            'movement_type', p_movement_type,
            'return_storage_point_id', p_return_storage_point_id,
            'from_user_id', p_from_user_id,
            'to_user_id', p_to_user_id,
            'accounting_act_number', p_accounting_act_number
        ),
        p_user_id
    );

    RETURN v_movement_id;
END;
$$;