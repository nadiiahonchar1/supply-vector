-- =========================================================
-- 1. IDEMPOTENCY INDEXES
-- =========================================================

CREATE UNIQUE INDEX idx_shipment_loading_operation_key
    ON shipment_loading_movements(operation_key);

CREATE UNIQUE INDEX idx_shipment_receipt_operation_key
    ON shipment_receipt_movements(operation_key);


-- =========================================================
-- 2. LOAD SHIPMENT CARGO
-- =========================================================

CREATE OR REPLACE FUNCTION load_shipment_item(
    p_shipment_item_id UUID,
    p_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_reservation RECORD;

    v_loaded_quantity INTEGER;
    v_remaining_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Loading quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    PERFORM 1
    FROM shipment_loading_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        SELECT id
        INTO v_item
        FROM shipment_loading_movements
        WHERE operation_key = p_operation_key;

        RETURN v_item.id;
    END IF;

    SELECT
        si.id,
        si.shipment_id,
        si.transfer_request_source_id,
        si.product_id,
        si.planned_quantity,
        s.status AS shipment_status,
        s.source_storage_point_id,
        s.trip_id,
        t.status AS trip_status
    INTO v_item
    FROM shipment_items si
    JOIN shipments s
        ON s.id = si.shipment_id
    LEFT JOIN trips t
        ON t.id = s.trip_id
    WHERE si.id = p_shipment_item_id
    FOR UPDATE OF si, s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shipment item not found';
    END IF;

    IF v_item.shipment_status NOT IN ('pending', 'in_progress') THEN
        RAISE EXCEPTION
            'Shipment cannot be loaded in its current status';
    END IF;

    IF v_item.trip_id IS NULL
       OR v_item.trip_status NOT IN ('ready', 'in_transit') THEN
        RAISE EXCEPTION
            'Shipment must be assigned to a ready or in-transit trip';
    END IF;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_loaded_quantity
    FROM shipment_loading_movements
    WHERE shipment_item_id = p_shipment_item_id;

    v_remaining_quantity :=
        v_item.planned_quantity - v_loaded_quantity;

    IF p_quantity > v_remaining_quantity THEN
        RAISE EXCEPTION
            'Loading exceeds planned quantity. Remaining: %, requested: %',
            v_remaining_quantity,
            p_quantity;
    END IF;

    SELECT ir.id
    INTO v_reservation
    FROM inventory_reservations ir
    JOIN inventory i
        ON i.id = ir.inventory_id
    WHERE ir.transfer_request_source_id =
            v_item.transfer_request_source_id
      AND i.storage_point_id = v_item.source_storage_point_id
      AND i.product_id = v_item.product_id
      AND (
          ir.reserved_quantity
          - ir.consumed_quantity
          - ir.released_quantity
      ) >= p_quantity
    FOR UPDATE OF ir;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No sufficient reservation found for shipment item';
    END IF;

    PERFORM consume_inventory_reservation(
        v_reservation.id,
        p_quantity,
        p_shipment_item_id,
        p_user_id,
        p_operation_key
    );

    INSERT INTO shipment_loading_movements (
        shipment_item_id,
        quantity,
        operation_key,
        loaded_by,
        comment
    )
    VALUES (
        p_shipment_item_id,
        p_quantity,
        p_operation_key,
        p_user_id,
        p_comment
    );

    UPDATE shipments
    SET
        status = 'in_progress',
        updated_at = NOW()
    WHERE id = v_item.shipment_id
      AND status = 'pending';

    INSERT INTO shipment_events (
        shipment_id,
        event_type,
        old_status,
        new_status,
        description,
        metadata,
        created_by
    )
    VALUES (
        v_item.shipment_id,
        'cargo_loaded',
        CASE
            WHEN v_loaded_quantity = 0 THEN 'pending'
            ELSE 'in_progress'
        END,
        'in_progress',
        'Shipment cargo physically loaded',
        jsonb_build_object(
            'shipment_item_id', p_shipment_item_id,
            'quantity', p_quantity
        ),
        p_user_id
    );

    RETURN p_operation_key;
END;
$$;


-- =========================================================
-- 3. RECEIVE SHIPMENT CARGO
-- =========================================================

CREATE OR REPLACE FUNCTION receive_shipment_item(
    p_shipment_item_id UUID,
    p_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
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
    v_other_resolved_quantity INTEGER;
    v_remaining_quantity INTEGER;

    v_quantity_before INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Receipt quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    PERFORM 1
    FROM shipment_receipt_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        RETURN p_operation_key;
    END IF;

    SELECT
        si.id,
        si.shipment_id,
        si.product_id,
        s.status AS shipment_status,
        s.destination_storage_point_id
    INTO v_item
    FROM shipment_items si
    JOIN shipments s
        ON s.id = si.shipment_id
    WHERE si.id = p_shipment_item_id
    FOR UPDATE OF si, s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shipment item not found';
    END IF;

    IF v_item.shipment_status NOT IN (
        'in_progress',
        'partially_delivered'
    ) THEN
        RAISE EXCEPTION
            'Shipment cannot be received in its current status';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM employees e
        JOIN storage_point_responsibles spr
            ON spr.employee_id = e.id
        WHERE e.user_id = p_user_id
          AND e.is_active = TRUE
          AND spr.storage_point_id =
                v_item.destination_storage_point_id
          AND spr.valid_from <= CURRENT_DATE
          AND (
              spr.valid_until IS NULL
              OR spr.valid_until >= CURRENT_DATE
          )
    ) THEN
        RAISE EXCEPTION
            'Only a currently assigned destination responsible person can receive cargo';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM storage_points
        WHERE id = v_item.destination_storage_point_id
          AND status = 'closed'
    ) THEN
        RAISE EXCEPTION
            'Cargo cannot be received at a closed storage point';
    END IF;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_loaded_quantity
    FROM shipment_loading_movements
    WHERE shipment_item_id = p_shipment_item_id;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_received_quantity
    FROM shipment_receipt_movements
    WHERE shipment_item_id = p_shipment_item_id;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_other_resolved_quantity
    FROM shipment_cargo_movements
    WHERE shipment_item_id = p_shipment_item_id;

    v_remaining_quantity :=
        v_loaded_quantity
        - v_received_quantity
        - v_other_resolved_quantity;

    IF p_quantity > v_remaining_quantity THEN
        RAISE EXCEPTION
            'Receipt exceeds unresolved loaded cargo. Remaining: %, requested: %',
            v_remaining_quantity,
            p_quantity;
    END IF;

    INSERT INTO inventory (
        storage_point_id,
        product_id,
        quantity,
        reserved_quantity,
        blocked_quantity
    )
    VALUES (
        v_item.destination_storage_point_id,
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
    WHERE storage_point_id = v_item.destination_storage_point_id
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
        'shipment_receive',
        p_quantity,
        v_quantity_before,
        v_quantity_before + p_quantity,
        'shipment_item',
        p_shipment_item_id,
        'Physical receipt of shipment cargo',
        p_user_id
    );

    INSERT INTO shipment_receipt_movements (
        shipment_item_id,
        quantity,
        operation_key,
        received_by,
        comment
    )
    VALUES (
        p_shipment_item_id,
        p_quantity,
        p_operation_key,
        p_user_id,
        p_comment
    );

    INSERT INTO shipment_events (
        shipment_id,
        event_type,
        description,
        metadata,
        created_by
    )
    VALUES (
        v_item.shipment_id,
        'cargo_received',
        'Shipment cargo physically received',
        jsonb_build_object(
            'shipment_item_id', p_shipment_item_id,
            'quantity', p_quantity
        ),
        p_user_id
    );

    RETURN p_operation_key;
END;
$$;