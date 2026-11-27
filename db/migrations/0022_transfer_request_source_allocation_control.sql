-- =========================================================
-- 1. SOURCE ALLOCATION CHANGE HISTORY
-- =========================================================

CREATE TABLE transfer_request_source_allocation_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_source_id UUID NOT NULL
        REFERENCES transfer_request_sources(id) ON DELETE RESTRICT,

    old_quantity INTEGER NOT NULL
        CHECK (old_quantity > 0),

    new_quantity INTEGER NOT NULL
        CHECK (new_quantity > 0),

    reason TEXT NOT NULL
        CHECK (LENGTH(BTRIM(reason)) BETWEEN 1 AND 2000),

    operation_key UUID NOT NULL UNIQUE,

    changed_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_source_allocation_history_values_differ
        CHECK (old_quantity <> new_quantity)
);


CREATE INDEX idx_source_allocation_history_source
    ON transfer_request_source_allocation_history(
        transfer_request_source_id,
        changed_at DESC
    );


-- =========================================================
-- 2. IMMUTABLE SOURCE ALLOCATION HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_source_allocation_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'SOURCE_ALLOCATION_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_source_allocation_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_source_allocation_history
FOR EACH ROW
EXECUTE FUNCTION prevent_source_allocation_history_mutation();


-- =========================================================
-- 3. VALIDATE TOTAL SOURCE ALLOCATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_item_id UUID;
    v_requested_quantity INTEGER;
    v_allocated_quantity BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_item_id := OLD.transfer_request_item_id;
    ELSE
        v_item_id := NEW.transfer_request_item_id;
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.transfer_request_item_id
           IS DISTINCT FROM OLD.transfer_request_item_id THEN
        RAISE EXCEPTION 'SOURCE_ITEM_REASSIGNMENT_NOT_ALLOWED';
    END IF;

    SELECT requested_quantity
    INTO v_requested_quantity
    FROM transfer_request_items
    WHERE id = v_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_ITEM_NOT_FOUND';
    END IF;

    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_allocated_quantity
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_item_id
      AND (
          TG_OP = 'INSERT'
          OR id <> OLD.id
      );

    IF TG_OP <> 'DELETE' THEN
        v_allocated_quantity :=
            v_allocated_quantity + NEW.allocated_quantity;
    END IF;

    IF v_allocated_quantity > v_requested_quantity THEN
        RAISE EXCEPTION 'SOURCE_ALLOCATION_EXCEEDS_REQUESTED_QUANTITY';
    END IF;

    RETURN CASE
        WHEN TG_OP = 'DELETE' THEN OLD
        ELSE NEW
    END;
END;
$$;


CREATE TRIGGER trg_transfer_request_source_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_allocation();


-- =========================================================
-- 4. VALIDATE SOURCE ALLOCATION AGAINST LOGISTICS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_source_allocation_logistics(
    p_source_id UUID,
    p_new_quantity INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_active_reserved BIGINT := 0;
    v_loaded_quantity BIGINT := 0;
    v_unloaded_quantity BIGINT := 0;
    v_committed_quantity BIGINT := 0;
BEGIN
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
    WHERE ir.transfer_request_source_id = p_source_id;

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
        )
    INTO
        v_loaded_quantity,
        v_unloaded_quantity
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    WHERE si.transfer_request_source_id = p_source_id;

    v_committed_quantity :=
        v_loaded_quantity - v_unloaded_quantity;

    IF v_committed_quantity < 0 THEN
        RAISE EXCEPTION 'INVALID_SOURCE_CARGO_BALANCE';
    END IF;

    IF v_active_reserved < 0 THEN
        RAISE EXCEPTION 'INVALID_SOURCE_RESERVATION_BALANCE';
    END IF;

    IF p_new_quantity <
       GREATEST(v_active_reserved, v_committed_quantity) THEN
        RAISE EXCEPTION 'SOURCE_ALLOCATION_BELOW_LOGISTIC_COMMITMENT';
    END IF;
END;
$$;


-- =========================================================
-- 5. CHANGE SOURCE ALLOCATION
-- =========================================================

CREATE OR REPLACE FUNCTION change_transfer_request_source_allocation(
    p_source_id UUID,
    p_new_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_source RECORD;
    v_item RECORD;
    v_request RECORD;
    v_existing RECORD;

    v_total_other BIGINT := 0;
    v_history_id UUID;
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
    FROM transfer_request_source_allocation_history
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_source_id <> p_source_id
           OR v_existing.new_quantity <> p_new_quantity
           OR v_existing.changed_by <> p_user_id
           OR v_existing.reason <> BTRIM(p_reason) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;
    
    SELECT transfer_request_item_id
    INTO v_item.id
    FROM transfer_request_sources
    WHERE id = p_source_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;
   
    SELECT *
    INTO v_item
    FROM transfer_request_items
    WHERE id = v_item.id
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

    IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    SELECT *
    INTO v_source
    FROM transfer_request_sources
    WHERE id = p_source_id
      AND transfer_request_item_id = v_item.id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    IF p_new_quantity = v_source.allocated_quantity THEN
        RAISE EXCEPTION 'QUANTITY_UNCHANGED';
    END IF;

    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_total_other
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_item.id
      AND id <> p_source_id;

    IF v_total_other + p_new_quantity > v_item.requested_quantity THEN
        RAISE EXCEPTION 'SOURCE_ALLOCATION_EXCEEDS_REQUESTED_QUANTITY';
    END IF;

    PERFORM validate_source_allocation_logistics(
        p_source_id,
        p_new_quantity
    );

    UPDATE transfer_request_sources
    SET
        allocated_quantity = p_new_quantity,
        updated_at = NOW()
    WHERE id = p_source_id;

    INSERT INTO transfer_request_source_allocation_history (
        transfer_request_source_id,
        old_quantity,
        new_quantity,
        reason,
        operation_key,
        changed_by
    )
    VALUES (
        p_source_id,
        v_source.allocated_quantity,
        p_new_quantity,
        BTRIM(p_reason),
        p_operation_key,
        p_user_id
    )
    RETURNING id INTO v_history_id;

    RETURN v_history_id;
END;
$$;