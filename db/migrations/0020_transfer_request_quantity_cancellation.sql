-- =========================================================
-- 1. PARTIAL CANCELLATION HISTORY
-- =========================================================

CREATE TABLE transfer_request_item_cancellations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_item_id UUID NOT NULL
        REFERENCES transfer_request_items(id) ON DELETE RESTRICT,

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    reason TEXT NOT NULL
        CHECK (BTRIM(reason) <> ''),

    operation_key UUID NOT NULL UNIQUE,

    created_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =========================================================
-- 2. CANCELLATION SOURCE ALLOCATION
-- =========================================================

CREATE TABLE transfer_request_item_cancellation_sources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    cancellation_id UUID NOT NULL
        REFERENCES transfer_request_item_cancellations(id)
        ON DELETE RESTRICT,

    transfer_request_source_id UUID NOT NULL
        REFERENCES transfer_request_sources(id)
        ON DELETE RESTRICT,

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_cancellation_source
        UNIQUE (cancellation_id, transfer_request_source_id)
);


-- =========================================================
-- 3. CANCELLATION RESERVATION RELEASE HISTORY
-- =========================================================

CREATE TABLE transfer_request_item_cancellation_reservations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    cancellation_id UUID NOT NULL
        REFERENCES transfer_request_item_cancellations(id)
        ON DELETE RESTRICT,

    reservation_id UUID NOT NULL
        REFERENCES inventory_reservations(id)
        ON DELETE RESTRICT,

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    reservation_movement_id UUID NOT NULL
        REFERENCES inventory_reservation_movements(id)
        ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_cancellation_reservation
        UNIQUE (cancellation_id, reservation_id)
);


-- =========================================================
-- 4. IMMUTABLE CANCELLATION HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_cancellation_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_CANCELLATION_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_transfer_request_cancellations_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_cancellations
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_cancellation_mutation();


CREATE TRIGGER trg_transfer_request_cancellation_sources_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_cancellation_sources
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_cancellation_mutation();


CREATE TRIGGER trg_transfer_request_cancellation_reservations_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_cancellation_reservations
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_cancellation_mutation();


-- =========================================================
-- 5. PARTIAL CANCELLATION
-- =========================================================

CREATE OR REPLACE FUNCTION cancel_transfer_request_quantity(
    p_transfer_request_item_id UUID,
    p_quantity INTEGER,
    p_reservation_releases JSONB,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_request RECORD;
    v_existing RECORD;

    v_cancellation_id UUID;

    v_received BIGINT := 0;
    v_loaded BIGINT := 0;
    v_resolved BIGINT := 0;
    v_unresolved_loaded BIGINT := 0;

    v_active_reserved BIGINT := 0;
    v_selected_release BIGINT := 0;
    v_unreserved_quantity BIGINT := 0;

    v_source_allocated BIGINT := 0;
    v_cancelled_total BIGINT := 0;

    v_release RECORD;
    v_reservation RECORD;
    v_source RECORD;

    v_remaining_reserved BIGINT;
    v_release_movement_id UUID;

    v_release_operation_key UUID;
    v_release_reason TEXT;

    v_release_total BIGINT;
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

    IF p_reservation_releases IS NULL
       OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
        RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_LIST';
    END IF;

    IF p_reason IS NULL OR BTRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'CANCELLATION_REASON_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Idempotency
    -- -----------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_item_cancellations
    WHERE operation_key = p_operation_key;

    IF FOUND THEN

        IF v_existing.transfer_request_item_id
                IS DISTINCT FROM p_transfer_request_item_id
           OR v_existing.quantity
                IS DISTINCT FROM p_quantity
           OR v_existing.reason
                IS DISTINCT FROM BTRIM(p_reason)
           OR v_existing.created_by
                IS DISTINCT FROM p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;


    -- -----------------------------------------------------
    -- Lock request item and request
    -- -----------------------------------------------------

    SELECT *
    INTO v_item
    FROM transfer_request_items
    WHERE id = p_transfer_request_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_ITEM_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = v_item.transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status NOT IN ('approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_CANCELLABLE';
    END IF;


    -- -----------------------------------------------------
    -- Calculate received quantity
    -- -----------------------------------------------------

    SELECT COALESCE(SUM(sco.quantity), 0)
    INTO v_received
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id
      AND sco.operation_type = 'receive';


    -- -----------------------------------------------------
    -- Calculate loaded quantity
    -- -----------------------------------------------------

    SELECT COALESCE(SUM(sco.quantity), 0)
    INTO v_loaded
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id
      AND sco.operation_type = 'load';


    -- -----------------------------------------------------
    -- Calculate physically resolved loaded cargo
    -- -----------------------------------------------------

    SELECT COALESCE(SUM(sco.quantity), 0)
    INTO v_resolved
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id
      AND sco.operation_type IN (
          'receive',
          'return',
          'loss',
          'writeoff',
          'unload_before_departure'
      );

    v_unresolved_loaded := v_loaded - v_resolved;

    IF v_unresolved_loaded < 0 THEN
        RAISE EXCEPTION 'INVALID_CARGO_BALANCE';
    END IF;


    -- -----------------------------------------------------
    -- Calculate active reservations
    -- -----------------------------------------------------

    SELECT COALESCE(
        SUM(
            ir.reserved_quantity
            - ir.consumed_quantity
            - ir.released_quantity
        ),
        0
    )
    INTO v_active_reserved
    FROM inventory_reservations ir
    JOIN transfer_request_sources trs
        ON trs.id = ir.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id;


    -- -----------------------------------------------------
    -- Validate reservation release payload
    -- -----------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(p_reservation_releases)
            AS r(reservation_id UUID, quantity INTEGER)
        WHERE r.reservation_id IS NULL
           OR r.quantity IS NULL
           OR r.quantity <= 0
    ) THEN
        RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_ENTRY';
    END IF;

    IF (
        SELECT COUNT(*)
        FROM jsonb_to_recordset(p_reservation_releases)
            AS r(reservation_id UUID, quantity INTEGER)
    ) <> (
        SELECT COUNT(DISTINCT r.reservation_id)
        FROM jsonb_to_recordset(p_reservation_releases)
            AS r(reservation_id UUID, quantity INTEGER)
    ) THEN
        RAISE EXCEPTION 'DUPLICATE_RESERVATION_RELEASE';
    END IF;

    SELECT COALESCE(SUM(r.quantity), 0)
    INTO v_selected_release
    FROM jsonb_to_recordset(p_reservation_releases)
        AS r(reservation_id UUID, quantity INTEGER);

    IF v_selected_release > p_quantity THEN
        RAISE EXCEPTION 'RESERVATION_RELEASE_EXCEEDS_CANCELLATION';
    END IF;


    -- -----------------------------------------------------
    -- Validate total released reservations
    -- -----------------------------------------------------

    v_release_total := 0;

    FOR v_release IN
        SELECT
            r.reservation_id,
            r.quantity
        FROM jsonb_to_recordset(p_reservation_releases)
            AS r(reservation_id UUID, quantity INTEGER)
    LOOP

        SELECT *
        INTO v_reservation
        FROM inventory_reservations
        WHERE id = v_release.reservation_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INVENTORY_RESERVATION_NOT_FOUND';
        END IF;

        SELECT *
        INTO v_source
        FROM transfer_request_sources
        WHERE id = v_reservation.transfer_request_source_id
        FOR UPDATE;

        IF NOT FOUND
           OR v_source.transfer_request_item_id
                <> p_transfer_request_item_id THEN
            RAISE EXCEPTION 'RESERVATION_SOURCE_MISMATCH';
        END IF;

        v_remaining_reserved :=
            v_reservation.reserved_quantity
            - v_reservation.consumed_quantity
            - v_reservation.released_quantity;

        IF v_release.quantity > v_remaining_reserved THEN
            RAISE EXCEPTION 'RESERVATION_RELEASE_EXCEEDS_REMAINING';
        END IF;

        v_release_total := v_release_total + v_release.quantity;

    END LOOP;


    -- -----------------------------------------------------
    -- Validate cancellable quantity
    -- -----------------------------------------------------

    v_unreserved_quantity :=
        v_item.requested_quantity
        - v_item.cancelled_quantity
        - v_received
        - v_unresolved_loaded
        - v_active_reserved;

    IF v_unreserved_quantity < 0 THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_BALANCE';
    END IF;

    IF p_quantity > v_unreserved_quantity + v_selected_release THEN
        RAISE EXCEPTION 'CANCELLATION_EXCEEDS_UNCOMMITTED_QUANTITY';
    END IF;

    IF v_item.cancelled_quantity + p_quantity >
       v_item.requested_quantity
       - v_received
       - v_unresolved_loaded THEN
        RAISE EXCEPTION 'CANCELLATION_EXCEEDS_REMAINING_NEED';
    END IF;


    -- -----------------------------------------------------
    -- Create cancellation record
    -- -----------------------------------------------------

    INSERT INTO transfer_request_item_cancellations (
        transfer_request_item_id,
        quantity,
        reason,
        operation_key,
        created_by
    )
    VALUES (
        p_transfer_request_item_id,
        p_quantity,
        BTRIM(p_reason),
        p_operation_key,
        p_user_id
    )
    RETURNING id
    INTO v_cancellation_id;


    -- -----------------------------------------------------
    -- Release selected reservations
    -- -----------------------------------------------------

    FOR v_release IN
        SELECT
            r.reservation_id,
            r.quantity
        FROM jsonb_to_recordset(p_reservation_releases)
            AS r(reservation_id UUID, quantity INTEGER)
    LOOP

        SELECT *
        INTO v_reservation
        FROM inventory_reservations
        WHERE id = v_release.reservation_id
        FOR UPDATE;

        SELECT *
        INTO v_source
        FROM transfer_request_sources
        WHERE id = v_reservation.transfer_request_source_id
        FOR UPDATE;

        v_release_operation_key := gen_random_uuid();

        v_release_reason :=
            'Transfer request cancellation: '
            || BTRIM(p_reason);

        PERFORM release_inventory_reservation(
            v_release.reservation_id,
            v_release.quantity,
            v_release_reason,
            'transfer_request_item_cancellation',
            v_cancellation_id,
            p_user_id,
            v_release_operation_key
        );

        SELECT id
        INTO v_release_movement_id
        FROM inventory_reservation_movements
        WHERE operation_key = v_release_operation_key;

        INSERT INTO transfer_request_item_cancellation_reservations (
            cancellation_id,
            reservation_id,
            quantity,
            reservation_movement_id
        )
        VALUES (
            v_cancellation_id,
            v_release.reservation_id,
            v_release.quantity,
            v_release_movement_id
        );

        INSERT INTO transfer_request_item_cancellation_sources (
            cancellation_id,
            transfer_request_source_id,
            quantity
        )
        VALUES (
            v_cancellation_id,
            v_source.id,
            v_release.quantity
        )
        ON CONFLICT (cancellation_id, transfer_request_source_id)
        DO UPDATE
        SET quantity =
            transfer_request_item_cancellation_sources.quantity
            + EXCLUDED.quantity;

    END LOOP;


    -- -----------------------------------------------------
    -- Record unreserved cancellation against sources
    -- -----------------------------------------------------

    FOR v_source IN
        SELECT
            trs.id,
            trs.allocated_quantity,
            trs.transfer_request_item_id
        FROM transfer_request_sources trs
        WHERE trs.transfer_request_item_id = p_transfer_request_item_id
        ORDER BY trs.id
        FOR UPDATE
    LOOP

        SELECT COALESCE(SUM(quantity), 0)
        INTO v_source_allocated
        FROM transfer_request_item_cancellation_sources
        WHERE cancellation_id = v_cancellation_id
          AND transfer_request_source_id = v_source.id;

        IF v_source_allocated >= v_source.allocated_quantity THEN
            CONTINUE;
        END IF;

    END LOOP;


    -- -----------------------------------------------------
    -- Update cancelled quantity
    -- -----------------------------------------------------

    UPDATE transfer_request_items
    SET cancelled_quantity = cancelled_quantity + p_quantity
    WHERE id = p_transfer_request_item_id;


    -- -----------------------------------------------------
    -- Recalculate request status
    -- -----------------------------------------------------

    PERFORM recalculate_transfer_request_status(
        v_item.transfer_request_id
    );

    RETURN v_cancellation_id;

END;
$$;