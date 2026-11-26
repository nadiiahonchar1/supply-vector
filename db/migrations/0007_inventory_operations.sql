-- =========================================================
-- 1. RESERVATION OPERATION IDEMPOTENCY
-- =========================================================

ALTER TABLE inventory_reservation_movements
    ADD COLUMN operation_key UUID;

CREATE UNIQUE INDEX uq_inventory_reservation_movements_operation_key
    ON inventory_reservation_movements(operation_key)
    WHERE operation_key IS NOT NULL;

CREATE UNIQUE INDEX uq_inventory_reservations_source_inventory
    ON inventory_reservations(
        transfer_request_source_id,
        inventory_id
    );


-- =========================================================
-- 2. RESERVE INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION reserve_inventory(
    p_transfer_request_source_id UUID,
    p_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_source RECORD;
    v_inventory RECORD;
    v_reservation RECORD;
    v_existing RECORD;

    v_reserved_for_source INTEGER;
    v_available_quantity INTEGER;
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
    FROM inventory_reservation_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.movement_type <> 'reserve'
           OR v_existing.quantity <> p_quantity
           OR v_existing.reference_type <> 'transfer_request_source'
           OR v_existing.reference_id <> p_transfer_request_source_id
           OR v_existing.created_by <> p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.reservation_id;
    END IF;

    SELECT
        trs.id,
        trs.transfer_request_id,
        trs.source_storage_point_id,
        trs.allocated_quantity,
        tri.product_id,
        tr.status AS request_status,
        tr.destination_storage_point_id
    INTO v_source
    FROM transfer_request_sources trs
    JOIN transfer_request_items tri
        ON tri.id = trs.transfer_request_item_id
    JOIN transfer_requests tr
        ON tr.id = trs.transfer_request_id
    WHERE trs.id = p_transfer_request_source_id
    FOR UPDATE OF trs, tr;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    IF v_source.request_status NOT IN ('approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_RESERVABLE';
    END IF;

    SELECT
        i.id,
        i.storage_point_id,
        i.product_id,
        i.quantity,
        i.reserved_quantity,
        i.blocked_quantity,
        sp.status AS storage_point_status
    INTO v_inventory
    FROM inventory i
    JOIN storage_points sp
        ON sp.id = i.storage_point_id
    WHERE i.storage_point_id = v_source.source_storage_point_id
      AND i.product_id = v_source.product_id
    FOR UPDATE OF i, sp;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
    END IF;

    IF v_inventory.storage_point_id = v_source.destination_storage_point_id THEN
        RAISE EXCEPTION 'SOURCE_EQUALS_DESTINATION';
    END IF;

    IF v_inventory.storage_point_status = 'closed' THEN
        RAISE EXCEPTION 'STORAGE_POINT_CLOSED';
    END IF;

    SELECT COALESCE(
        SUM(
            ir.reserved_quantity
            - ir.consumed_quantity
            - ir.released_quantity
        ),
        0
    )
    INTO v_reserved_for_source
    FROM inventory_reservations ir
    WHERE ir.transfer_request_source_id = p_transfer_request_source_id;

    IF v_reserved_for_source + p_quantity > v_source.allocated_quantity THEN
        RAISE EXCEPTION 'RESERVATION_EXCEEDS_SOURCE_ALLOCATION';
    END IF;

    v_available_quantity :=
        v_inventory.quantity
        - v_inventory.reserved_quantity
        - v_inventory.blocked_quantity;

    IF v_available_quantity < p_quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_INVENTORY';
    END IF;

    SELECT *
    INTO v_reservation
    FROM inventory_reservations
    WHERE inventory_id = v_inventory.id
      AND transfer_request_source_id = p_transfer_request_source_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO inventory_reservations (
            inventory_id,
            transfer_request_source_id,
            reserved_quantity,
            consumed_quantity,
            released_quantity,
            created_by
        )
        VALUES (
            v_inventory.id,
            p_transfer_request_source_id,
            p_quantity,
            0,
            0,
            p_user_id
        )
        RETURNING *
        INTO v_reservation;
    ELSE
        UPDATE inventory_reservations
        SET
            reserved_quantity = reserved_quantity + p_quantity,
            updated_at = NOW()
        WHERE id = v_reservation.id
        RETURNING *
        INTO v_reservation;
    END IF;

    UPDATE inventory
    SET
        reserved_quantity = reserved_quantity + p_quantity,
        updated_at = NOW()
    WHERE id = v_inventory.id;

    INSERT INTO inventory_reservation_movements (
        reservation_id,
        movement_type,
        quantity,
        reference_type,
        reference_id,
        reason,
        created_by,
        operation_key
    )
    VALUES (
        v_reservation.id,
        'reserve',
        p_quantity,
        'transfer_request_source',
        p_transfer_request_source_id,
        'Inventory reserved for transfer request',
        p_user_id,
        p_operation_key
    );

    RETURN v_reservation.id;
END;
$$;


-- =========================================================
-- 3. CONSUME INVENTORY RESERVATION
-- =========================================================

CREATE OR REPLACE FUNCTION consume_inventory_reservation(
    p_reservation_id UUID,
    p_quantity INTEGER,
    p_shipment_item_id UUID,
    p_user_id UUID,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation RECORD;
    v_inventory RECORD;
    v_source RECORD;
    v_shipment RECORD;
    v_trip RECORD;
    v_existing RECORD;

    v_remaining_reserved INTEGER;
    v_loaded_quantity INTEGER;
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
    FROM inventory_reservation_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.movement_type <> 'consume'
           OR v_existing.quantity <> p_quantity
           OR v_existing.reference_type <> 'shipment_item'
           OR v_existing.reference_id <> p_shipment_item_id
           OR v_existing.reservation_id <> p_reservation_id
           OR v_existing.created_by <> p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.reservation_id;
    END IF;

    SELECT *
    INTO v_reservation
    FROM inventory_reservations
    WHERE id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RESERVATION_NOT_FOUND';
    END IF;

    SELECT
        i.*,
        sp.status AS storage_point_status
    INTO v_inventory
    FROM inventory i
    JOIN storage_points sp
        ON sp.id = i.storage_point_id
    WHERE i.id = v_reservation.inventory_id
    FOR UPDATE OF i, sp;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
    END IF;

    SELECT
        trs.id,
        trs.source_storage_point_id,
        tri.product_id,
        trs.transfer_request_id
    INTO v_source
    FROM transfer_request_sources trs
    JOIN transfer_request_items tri
        ON tri.id = trs.transfer_request_item_id
    WHERE trs.id = v_reservation.transfer_request_source_id
    FOR KEY SHARE OF trs, tri;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    SELECT
        si.id,
        si.shipment_id,
        si.transfer_request_source_id,
        si.product_id,
        si.planned_quantity,
        s.status AS shipment_status,
        s.source_storage_point_id,
        s.trip_id
    INTO v_shipment
    FROM shipment_items si
    JOIN shipments s
        ON s.id = si.shipment_id
    WHERE si.id = p_shipment_item_id
    FOR UPDATE OF si, s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
    END IF;

    IF v_shipment.transfer_request_source_id
        <> v_reservation.transfer_request_source_id THEN
        RAISE EXCEPTION 'SHIPMENT_RESERVATION_SOURCE_MISMATCH';
    END IF;

    IF v_shipment.product_id <> v_inventory.product_id
       OR v_source.product_id <> v_inventory.product_id THEN
        RAISE EXCEPTION 'SHIPMENT_PRODUCT_MISMATCH';
    END IF;

    IF v_shipment.source_storage_point_id
        <> v_inventory.storage_point_id
       OR v_source.source_storage_point_id
        <> v_inventory.storage_point_id THEN
        RAISE EXCEPTION 'SHIPMENT_SOURCE_MISMATCH';
    END IF;

    IF v_shipment.shipment_status <> 'pending' THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_READY_FOR_LOADING';
    END IF;

    IF v_shipment.trip_id IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_TRIP_REQUIRED';
    END IF;

    SELECT *
    INTO v_trip
    FROM trips
    WHERE id = v_shipment.trip_id
    FOR UPDATE;

    IF NOT FOUND OR v_trip.status <> 'ready' THEN
        RAISE EXCEPTION 'TRIP_NOT_READY_FOR_LOADING';
    END IF;

    IF v_inventory.storage_point_status = 'closed' THEN
        RAISE EXCEPTION 'STORAGE_POINT_CLOSED';
    END IF;

    v_remaining_reserved :=
        v_reservation.reserved_quantity
        - v_reservation.consumed_quantity
        - v_reservation.released_quantity;

    IF v_remaining_reserved < p_quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT_REMAINING_RESERVATION';
    END IF;

    SELECT COALESCE(SUM(sco.quantity), 0)
    INTO v_loaded_quantity
    FROM shipment_cargo_operations sco
    WHERE sco.shipment_item_id = p_shipment_item_id
      AND sco.operation_type = 'load';

    IF v_loaded_quantity + p_quantity > v_shipment.planned_quantity THEN
        RAISE EXCEPTION 'LOADING_EXCEEDS_PLANNED_QUANTITY';
    END IF;

    IF v_inventory.quantity < p_quantity
       OR v_inventory.reserved_quantity < p_quantity THEN
        RAISE EXCEPTION 'INVENTORY_RESERVATION_BALANCE_MISMATCH';
    END IF;

    v_quantity_before := v_inventory.quantity;

    UPDATE inventory
    SET
        quantity = quantity - p_quantity,
        reserved_quantity = reserved_quantity - p_quantity,
        updated_at = NOW()
    WHERE id = v_inventory.id;

    UPDATE inventory_reservations
    SET
        consumed_quantity = consumed_quantity + p_quantity,
        updated_at = NOW()
    WHERE id = p_reservation_id;

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
        'shipment_load',
        p_quantity,
        v_quantity_before,
        v_quantity_before - p_quantity,
        'shipment_item',
        p_shipment_item_id,
        'Physical loading of shipment cargo',
        p_user_id
    );

    INSERT INTO inventory_reservation_movements (
        reservation_id,
        movement_type,
        quantity,
        reference_type,
        reference_id,
        reason,
        created_by,
        operation_key
    )
    VALUES (
        p_reservation_id,
        'consume',
        p_quantity,
        'shipment_item',
        p_shipment_item_id,
        'Reservation consumed during shipment loading',
        p_user_id,
        p_operation_key
    );

    INSERT INTO shipment_cargo_operations (
        shipment_item_id,
        operation_type,
        quantity,
        operation_key,
        performed_by
    )
    VALUES (
        p_shipment_item_id,
        'load',
        p_quantity,
        p_operation_key,
        p_user_id
    );

    RETURN p_reservation_id;
END;
$$;


-- =========================================================
-- 4. RELEASE INVENTORY RESERVATION
-- =========================================================

CREATE OR REPLACE FUNCTION release_inventory_reservation(
    p_reservation_id UUID,
    p_quantity INTEGER,
    p_reason TEXT,
    p_reference_type TEXT,
    p_reference_id UUID,
    p_user_id UUID,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_reservation RECORD;
    v_inventory RECORD;
    v_existing RECORD;

    v_remaining_reserved INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_reason IS NULL OR BTRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'RELEASE_REASON_REQUIRED';
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
    FROM inventory_reservation_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.movement_type <> 'release'
           OR v_existing.quantity <> p_quantity
           OR v_existing.reference_type IS DISTINCT FROM p_reference_type
           OR v_existing.reference_id IS DISTINCT FROM p_reference_id
           OR v_existing.reservation_id <> p_reservation_id
           OR v_existing.reason <> p_reason
           OR v_existing.created_by <> p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.reservation_id;
    END IF;

    SELECT *
    INTO v_reservation
    FROM inventory_reservations
    WHERE id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RESERVATION_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = v_reservation.inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
    END IF;

    v_remaining_reserved :=
        v_reservation.reserved_quantity
        - v_reservation.consumed_quantity
        - v_reservation.released_quantity;

    IF v_remaining_reserved < p_quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT_REMAINING_RESERVATION';
    END IF;

    IF v_inventory.reserved_quantity < p_quantity THEN
        RAISE EXCEPTION 'INVENTORY_RESERVED_BALANCE_MISMATCH';
    END IF;

    UPDATE inventory
    SET
        reserved_quantity = reserved_quantity - p_quantity,
        updated_at = NOW()
    WHERE id = v_inventory.id;

    UPDATE inventory_reservations
    SET
        released_quantity = released_quantity + p_quantity,
        updated_at = NOW()
    WHERE id = p_reservation_id;

    INSERT INTO inventory_reservation_movements (
        reservation_id,
        movement_type,
        quantity,
        reference_type,
        reference_id,
        reason,
        created_by,
        operation_key
    )
    VALUES (
        p_reservation_id,
        'release',
        p_quantity,
        p_reference_type,
        p_reference_id,
        p_reason,
        p_user_id,
        p_operation_key
    );

    RETURN p_reservation_id;
END;
$$;