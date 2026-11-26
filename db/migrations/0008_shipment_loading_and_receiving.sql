-- =========================================================
-- 1. RECEIVE SHIPMENT CARGO
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
    v_existing RECORD;

    v_loaded_quantity INTEGER;
    v_resolved_quantity INTEGER;
    v_remaining_quantity INTEGER;

    v_quantity_before INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM shipment_cargo_operations
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.operation_type <> 'receive'
           OR v_existing.shipment_item_id <> p_shipment_item_id
           OR v_existing.quantity <> p_quantity
           OR v_existing.performed_by <> p_user_id
           OR v_existing.comment IS DISTINCT FROM p_comment THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN p_operation_key;
    END IF;

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

    IF NOT EXISTS (
        SELECT 1
        FROM employees e
        JOIN storage_point_responsibles spr
            ON spr.employee_id = e.id
        WHERE e.user_id = p_user_id
          AND e.is_active = TRUE
          AND spr.storage_point_id = v_item.destination_storage_point_id
          AND spr.valid_from <= CURRENT_DATE
          AND (
              spr.valid_until IS NULL
              OR spr.valid_until >= CURRENT_DATE
          )
    ) THEN
        RAISE EXCEPTION 'DESTINATION_RESPONSIBLE_REQUIRED';
    END IF;

    PERFORM 1
    FROM storage_points
    WHERE id = v_item.destination_storage_point_id
      AND status <> 'closed'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DESTINATION_STORAGE_POINT_CLOSED';
    END IF;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_loaded_quantity
    FROM shipment_cargo_operations
    WHERE shipment_item_id = p_shipment_item_id
      AND operation_type = 'load';

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_resolved_quantity
    FROM shipment_cargo_operations
    WHERE shipment_item_id = p_shipment_item_id
      AND operation_type IN (
          'receive',
          'return',
          'loss',
          'writeoff'
      );

    v_remaining_quantity :=
        v_loaded_quantity - v_resolved_quantity;

    IF v_remaining_quantity < p_quantity THEN
        RAISE EXCEPTION 'RECEIPT_EXCEEDS_UNRESOLVED_CARGO';
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

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DESTINATION_INVENTORY_NOT_FOUND';
    END IF;

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

    INSERT INTO shipment_cargo_operations (
        shipment_item_id,
        operation_type,
        quantity,
        operation_key,
        comment,
        performed_by
    )
    VALUES (
        p_shipment_item_id,
        'receive',
        p_quantity,
        p_operation_key,
        p_comment,
        p_user_id
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
            'quantity', p_quantity,
            'operation_key', p_operation_key
        ),
        p_user_id
    );

    RETURN p_operation_key;
END;
$$;