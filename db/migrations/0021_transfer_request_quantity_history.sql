-- =========================================================
-- 1. TRANSFER REQUEST ITEM QUANTITY HISTORY
-- =========================================================

CREATE TABLE transfer_request_item_quantity_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_item_id UUID NOT NULL
        REFERENCES transfer_request_items(id) ON DELETE RESTRICT,

    old_quantity INTEGER NOT NULL
        CHECK (old_quantity > 0),

    new_quantity INTEGER NOT NULL
        CHECK (new_quantity > 0),

    change_reason TEXT NOT NULL
        CHECK (LENGTH(BTRIM(change_reason)) BETWEEN 1 AND 2000),

    operation_key UUID NOT NULL UNIQUE,

    changed_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_quantity_history_values_differ
        CHECK (old_quantity <> new_quantity)
);


CREATE INDEX idx_transfer_request_item_quantity_history
    ON transfer_request_item_quantity_history(
        transfer_request_item_id,
        changed_at DESC
    );


-- =========================================================
-- 2. IMMUTABLE QUANTITY HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_quantity_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_QUANTITY_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_transfer_request_quantity_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_quantity_history
FOR EACH ROW
EXECUTE FUNCTION prevent_quantity_history_mutation();


-- =========================================================
-- 3. CHANGE TRANSFER REQUEST ITEM QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION change_transfer_request_item_quantity(
    p_transfer_request_item_id UUID,
    p_new_quantity INTEGER,
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

    v_history_id UUID;

    v_received BIGINT := 0;
    v_loaded BIGINT := 0;
    v_unloaded_before_departure BIGINT := 0;
    v_resolved BIGINT := 0;
    v_unresolved_loaded BIGINT := 0;

    v_active_reserved BIGINT := 0;
    v_minimum_quantity BIGINT := 0;
BEGIN
    IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'CHANGE_REASON_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_item_quantity_history
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_item_id
                <> p_transfer_request_item_id
           OR v_existing.new_quantity <> p_new_quantity
           OR v_existing.changed_by <> p_user_id
           OR v_existing.change_reason <> BTRIM(p_reason) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

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
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    IF p_new_quantity = v_item.requested_quantity THEN
        RAISE EXCEPTION 'QUANTITY_UNCHANGED';
    END IF;

    -- =====================================================
    -- 4. CALCULATE RECEIVED CARGO
    -- =====================================================

    SELECT COALESCE(SUM(sco.quantity), 0)
    INTO v_received
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id
      AND sco.operation_type = 'receive';


    -- =====================================================
    -- 5. CALCULATE LOADED CARGO
    -- =====================================================

    SELECT
        COALESCE(
            SUM(sco.quantity) FILTER (
                WHERE sco.operation_type = 'load'
            ),
            0
        ),
        COALESCE(
            SUM(sco.quantity) FILTER (
                WHERE sco.operation_type = 'unload_before_departure'
            ),
            0
        ),
        COALESCE(
            SUM(sco.quantity) FILTER (
                WHERE sco.operation_type IN (
                    'return',
                    'loss',
                    'writeoff'
                )
            ),
            0
        )
    INTO
        v_loaded,
        v_unloaded_before_departure,
        v_resolved
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE trs.transfer_request_item_id = p_transfer_request_item_id;


    v_unresolved_loaded :=
        v_loaded
        - v_unloaded_before_departure
        - v_received
        - v_resolved;

    IF v_unresolved_loaded < 0 THEN
        RAISE EXCEPTION 'INVALID_SHIPMENT_CARGO_BALANCE';
    END IF;


    -- =====================================================
    -- 6. CALCULATE ACTIVE INVENTORY RESERVATIONS
    -- =====================================================

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

    IF v_active_reserved < 0 THEN
        RAISE EXCEPTION 'INVALID_INVENTORY_RESERVATION_BALANCE';
    END IF;


    -- =====================================================
    -- 7. VALIDATE THE NEW REQUESTED QUANTITY
    -- =====================================================

    v_minimum_quantity :=
        v_received
        + v_unresolved_loaded
        + v_active_reserved
        + v_item.cancelled_quantity;

    IF p_new_quantity < v_minimum_quantity THEN
        RAISE EXCEPTION 'QUANTITY_BELOW_COMMITTED_AMOUNT';
    END IF;


    -- =====================================================
    -- 8. UPDATE REQUESTED QUANTITY
    -- =====================================================

    UPDATE transfer_request_items
    SET
        requested_quantity = p_new_quantity,
        updated_at = NOW()
    WHERE id = p_transfer_request_item_id;


    -- =====================================================
    -- 9. RECORD QUANTITY CHANGE
    -- =====================================================

    INSERT INTO transfer_request_item_quantity_history (
        transfer_request_item_id,
        old_quantity,
        new_quantity,
        change_reason,
        operation_key,
        changed_by
    )
    VALUES (
        p_transfer_request_item_id,
        v_item.requested_quantity,
        p_new_quantity,
        BTRIM(p_reason),
        p_operation_key,
        p_user_id
    )
    RETURNING id INTO v_history_id;

    RETURN v_history_id;
END;
$$;