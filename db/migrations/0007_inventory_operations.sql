-- =========================================================
-- 1. IDEMPOTENCY FOR RESERVATION OPERATIONS
-- =========================================================

ALTER TABLE inventory_reservation_movements
ADD COLUMN operation_key UUID;

CREATE UNIQUE INDEX idx_inventory_reservation_movements_operation_key
    ON inventory_reservation_movements(operation_key)
    WHERE operation_key IS NOT NULL;

CREATE UNIQUE INDEX idx_inventory_reservations_source_inventory
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

    v_allocated_quantity INTEGER;
    v_already_reserved INTEGER;
    v_available_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Reservation quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    SELECT irm.reservation_id
    INTO v_reservation
    FROM inventory_reservation_movements irm
    WHERE irm.operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_reservation.reservation_id;
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
    FOR UPDATE OF trs;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer request source not found';
    END IF;

    IF v_source.request_status NOT IN ('approved', 'in_progress') THEN
        RAISE EXCEPTION
            'Inventory can only be reserved for approved or in-progress requests';
    END IF;

    SELECT
        id,
        storage_point_id,
        product_id,
        quantity,
        reserved_quantity,
        blocked_quantity
    INTO v_inventory
    FROM inventory
    WHERE storage_point_id = v_source.source_storage_point_id
      AND product_id = v_source.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
    END IF;

    IF v_inventory.storage_point_id = v_source.destination_storage_point_id THEN
        RAISE EXCEPTION 'Source and destination cannot be the same';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM storage_points
        WHERE id = v_source.source_storage_point_id
          AND status = 'closed'
    ) THEN
        RAISE EXCEPTION
            'Inventory cannot be reserved from a closed storage point';
    END IF;

    SELECT COALESCE(
        SUM(ir.reserved_quantity - ir.consumed_quantity - ir.released_quantity),
        0
    )
    INTO v_already_reserved
    FROM inventory_reservations ir
    WHERE ir.transfer_request_source_id = p_transfer_request_source_id;

    IF v_already_reserved + p_quantity > v_source.allocated_quantity THEN
        RAISE EXCEPTION
            'Reservation exceeds the source allocation quantity';
    END IF;

    v_available_quantity :=
        v_inventory.quantity
        - v_inventory.reserved_quantity
        - v_inventory.blocked_quantity;

    IF v_available_quantity < p_quantity THEN
        RAISE EXCEPTION
            'Insufficient available inventory. Available: %, requested: %',
            v_available_quantity,
            p_quantity;
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

    v_remaining_reserved INTEGER;
    v_quantity_before INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Consumption quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    SELECT irm.reservation_id
    INTO v_reservation
    FROM inventory_reservation_movements irm
    WHERE irm.operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_reservation.reservation_id;
    END IF;

    SELECT *
    INTO v_reservation
    FROM inventory_reservations
    WHERE id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory reservation not found';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = v_reservation.inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
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
    WHERE trs.id = v_reservation.transfer_request_source_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer request source not found';
    END IF;

    SELECT
        si.id,
        si.shipment_id,
        si.transfer_request_source_id,
        si.product_id,
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
        RAISE EXCEPTION 'Shipment item not found';
    END IF;

    IF v_shipment.transfer_request_source_id
        <> v_reservation.transfer_request_source_id THEN
        RAISE EXCEPTION
            'Shipment item does not belong to this reservation source';
    END IF;

    IF v_shipment.product_id <> v_inventory.product_id THEN
        RAISE EXCEPTION
            'Shipment product does not match inventory product';
    END IF;

    IF v_shipment.source_storage_point_id
        <> v_inventory.storage_point_id THEN
        RAISE EXCEPTION
            'Shipment source does not match inventory storage point';
    END IF;

    IF v_shipment.status NOT IN ('pending', 'in_progress') THEN
        RAISE EXCEPTION
            'Shipment cannot be loaded in its current status';
    END IF;

    IF v_shipment.trip_id IS NULL THEN
        RAISE EXCEPTION
            'Shipment must be assigned to a trip before loading';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM trips
        WHERE id = v_shipment.trip_id
          AND status IN ('ready', 'in_transit')
    ) THEN
        RAISE EXCEPTION
            'Trip must be ready or in transit before loading';
    END IF;

    v_remaining_reserved :=
        v_reservation.reserved_quantity
        - v_reservation.consumed_quantity
        - v_reservation.released_quantity;

    IF v_remaining_reserved < p_quantity THEN
        RAISE EXCEPTION
            'Insufficient remaining reservation. Available: %, requested: %',
            v_remaining_reserved,
            p_quantity;
    END IF;

    IF v_inventory.quantity < p_quantity
       OR v_inventory.reserved_quantity < p_quantity THEN
        RAISE EXCEPTION
            'Inventory balance is inconsistent with reservation';
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

    v_remaining_reserved INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Release quantity must be positive';
    END IF;

    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'Release reason is required';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    -- Idempotency check.
    SELECT irm.reservation_id
    INTO v_reservation
    FROM inventory_reservation_movements irm
    WHERE irm.operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_reservation.reservation_id;
    END IF;

    SELECT *
    INTO v_reservation
    FROM inventory_reservations
    WHERE id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory reservation not found';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = v_reservation.inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
    END IF;

    v_remaining_reserved :=
        v_reservation.reserved_quantity
        - v_reservation.consumed_quantity
        - v_reservation.released_quantity;

    IF v_remaining_reserved < p_quantity THEN
        RAISE EXCEPTION
            'Insufficient remaining reservation. Available: %, requested: %',
            v_remaining_reserved,
            p_quantity;
    END IF;

    IF v_inventory.reserved_quantity < p_quantity THEN
        RAISE EXCEPTION
            'Inventory reserved balance is inconsistent';
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