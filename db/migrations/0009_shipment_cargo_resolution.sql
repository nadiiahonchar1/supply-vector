-- =========================================================
-- 1. WRITEOFF ACCOUNTING INFORMATION
-- =========================================================

ALTER TABLE shipment_cargo_operations
    ADD COLUMN accounting_act_number TEXT;

ALTER TABLE shipment_cargo_operations
    ADD CONSTRAINT chk_shipment_cargo_writeoff_act
    CHECK (
        operation_type <> 'writeoff'
        OR (
            accounting_act_number IS NOT NULL
            AND BTRIM(accounting_act_number) <> ''
        )
    );


-- =========================================================
-- 2. CARGO RESOLUTION
-- =========================================================

CREATE OR REPLACE FUNCTION resolve_shipment_cargo(
    p_shipment_item_id UUID,
    p_operation_type TEXT,
    p_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason_code TEXT,
    p_return_storage_point_id UUID DEFAULT NULL,
    p_return_disposition TEXT DEFAULT NULL,
    p_accounting_act_number TEXT DEFAULT NULL,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_inventory RECORD;
    v_existing RECORD;
    v_return_point RECORD;

    v_loaded_quantity INTEGER;
    v_resolved_quantity INTEGER;
    v_remaining_quantity INTEGER;

    v_quantity_before INTEGER;
    v_block_id UUID;
BEGIN
    -- -----------------------------------------------------
    -- Basic validation
    -- -----------------------------------------------------

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    IF p_reason_code IS NULL OR BTRIM(p_reason_code) = '' THEN
        RAISE EXCEPTION 'CARGO_RESOLUTION_REASON_REQUIRED';
    END IF;

    IF p_operation_type NOT IN ('return', 'loss', 'writeoff') THEN
        RAISE EXCEPTION 'INVALID_CARGO_RESOLUTION_TYPE';
    END IF;

    IF p_operation_type = 'return' THEN
        IF p_return_storage_point_id IS NULL THEN
            RAISE EXCEPTION 'RETURN_STORAGE_POINT_REQUIRED';
        END IF;

        IF p_return_disposition NOT IN ('available', 'blocked') THEN
            RAISE EXCEPTION 'INVALID_RETURN_DISPOSITION';
        END IF;
    ELSE
        IF p_return_storage_point_id IS NOT NULL THEN
            RAISE EXCEPTION 'RETURN_STORAGE_POINT_NOT_ALLOWED';
        END IF;

        IF p_return_disposition IS NOT NULL THEN
            RAISE EXCEPTION 'RETURN_DISPOSITION_NOT_ALLOWED';
        END IF;
    END IF;

    IF p_operation_type = 'writeoff' THEN
        IF p_accounting_act_number IS NULL
           OR BTRIM(p_accounting_act_number) = '' THEN
            RAISE EXCEPTION 'WRITEOFF_ACCOUNTING_ACT_REQUIRED';
        END IF;
    ELSE
        IF p_accounting_act_number IS NOT NULL THEN
            RAISE EXCEPTION 'ACCOUNTING_ACT_NOT_ALLOWED';
        END IF;
    END IF;


    -- -----------------------------------------------------
    -- Idempotency
    -- -----------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM shipment_cargo_operations
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.shipment_item_id
                IS DISTINCT FROM p_shipment_item_id
           OR v_existing.operation_type
                IS DISTINCT FROM p_operation_type
           OR v_existing.quantity
                IS DISTINCT FROM p_quantity
           OR v_existing.performed_by
                IS DISTINCT FROM p_user_id
           OR v_existing.reason_code
                IS DISTINCT FROM p_reason_code
           OR v_existing.storage_point_id
                IS DISTINCT FROM p_return_storage_point_id
           OR v_existing.accounting_act_number
                IS DISTINCT FROM p_accounting_act_number
           OR v_existing.comment
                IS DISTINCT FROM p_comment THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;


    -- -----------------------------------------------------
    -- Validate actor
    -- -----------------------------------------------------

    IF NOT EXISTS (
        SELECT 1
        FROM users u
        JOIN employees e
            ON e.user_id = u.id
        WHERE u.id = p_user_id
          AND u.is_active = TRUE
          AND u.deleted_at IS NULL
          AND e.is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'ACTIVE_EMPLOYEE_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Lock shipment item and shipment
    -- -----------------------------------------------------

    SELECT
        si.id,
        si.shipment_id,
        si.product_id,
        si.planned_quantity,
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
        RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
    END IF;

    IF v_item.shipment_status <> 'in_transit' THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
    END IF;


    -- -----------------------------------------------------
    -- Calculate unresolved physical cargo
    -- -----------------------------------------------------

    SELECT
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type = 'load'
            ),
            0
        ),
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type IN (
                    'receive',
                    'return',
                    'loss',
                    'writeoff'
                )
            ),
            0
        )
    INTO
        v_loaded_quantity,
        v_resolved_quantity
    FROM shipment_cargo_operations
    WHERE shipment_item_id = p_shipment_item_id;

    v_remaining_quantity :=
        v_loaded_quantity - v_resolved_quantity;

    IF v_remaining_quantity < p_quantity THEN
        RAISE EXCEPTION 'RESOLUTION_EXCEEDS_UNRESOLVED_CARGO';
    END IF;


    -- -----------------------------------------------------
    -- Validate return storage point
    -- -----------------------------------------------------

    IF p_operation_type = 'return' THEN
        SELECT
            id,
            status
        INTO v_return_point
        FROM storage_points
        WHERE id = p_return_storage_point_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'RETURN_STORAGE_POINT_NOT_FOUND';
        END IF;

        IF v_return_point.status = 'closed' THEN
            RAISE EXCEPTION 'RETURN_STORAGE_POINT_CLOSED';
        END IF;
    END IF;


    -- -----------------------------------------------------
    -- Process physical return
    -- -----------------------------------------------------

    IF p_operation_type = 'return' THEN

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

        IF NOT FOUND THEN
            RAISE EXCEPTION 'RETURN_INVENTORY_NOT_FOUND';
        END IF;

        v_quantity_before := v_inventory.quantity;

        UPDATE inventory
        SET
            quantity = quantity + p_quantity,
            blocked_quantity = blocked_quantity
                + CASE
                    WHEN p_return_disposition = 'blocked'
                    THEN p_quantity
                    ELSE 0
                  END,
            updated_at = NOW()
        WHERE id = v_inventory.id;

        INSERT INTO inventory_movements (
            storage_point_id,
            product_id,
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
            p_return_storage_point_id,
            v_item.product_id,
            'shipment_return',
            p_quantity,
            v_quantity_before,
            v_quantity_before + p_quantity,
            'shipment_item',
            p_shipment_item_id,
            p_reason_code,
            p_user_id
        );

        -- Damaged or otherwise unsuitable returned cargo
        -- remains in stock but is excluded from availability.

        IF p_return_disposition = 'blocked' THEN

            INSERT INTO inventory_blocks (
                inventory_id,
                reason,
                initial_quantity,
                unblocked_quantity,
                created_by
            )
            VALUES (
                v_inventory.id,
                'damage',
                p_quantity,
                0,
                p_user_id
            )
            RETURNING id
            INTO v_block_id;

            INSERT INTO inventory_block_movements (
                block_id,
                movement_type,
                quantity,
                reference_type,
                reference_id,
                reason,
                comment,
                created_by
            )
            VALUES (
                v_block_id,
                'block',
                p_quantity,
                'shipment_item',
                p_shipment_item_id,
                p_reason_code,
                p_comment,
                p_user_id
            );

        END IF;

    END IF;


    -- -----------------------------------------------------
    -- Record cargo resolution
    -- -----------------------------------------------------

    INSERT INTO shipment_cargo_operations (
        shipment_item_id,
        operation_type,
        quantity,
        operation_key,
        storage_point_id,
        reason_code,
        comment,
        performed_by,
        accounting_act_number
    )
    VALUES (
        p_shipment_item_id,
        p_operation_type,
        p_quantity,
        p_operation_key,
        p_return_storage_point_id,
        p_reason_code,
        p_comment,
        p_user_id,
        p_accounting_act_number
    )
    RETURNING id
    INTO v_existing;


    -- -----------------------------------------------------
    -- Record shipment event
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
        'cargo_' || p_operation_type,
        p_reason_code,
        jsonb_build_object(
            'shipment_item_id', p_shipment_item_id,
            'quantity', p_quantity,
            'operation_type', p_operation_type,
            'return_storage_point_id',
                p_return_storage_point_id,
            'return_disposition',
                p_return_disposition,
            'accounting_act_number',
                p_accounting_act_number,
            'operation_key',
                p_operation_key
        ),
        p_user_id
    );

    RETURN v_existing.id;
END;
$$;