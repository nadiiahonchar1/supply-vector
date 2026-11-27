-- =========================================================
-- 1. SOURCE LIFECYCLE FIELDS
-- =========================================================

ALTER TABLE transfer_request_sources
ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE,
ADD COLUMN creation_operation_key UUID,
ADD COLUMN deactivated_by UUID REFERENCES users(id) ON DELETE RESTRICT,
ADD COLUMN deactivated_at TIMESTAMPTZ,
ADD COLUMN deactivation_reason TEXT;

ALTER TABLE transfer_request_sources
ADD CONSTRAINT chk_transfer_request_source_deactivation
CHECK (
    (
        is_active = TRUE
        AND deactivated_by IS NULL
        AND deactivated_at IS NULL
        AND deactivation_reason IS NULL
    )
    OR
    (
        is_active = FALSE
        AND deactivated_by IS NOT NULL
        AND deactivated_at IS NOT NULL
        AND deactivation_reason IS NOT NULL
        AND LENGTH(BTRIM(deactivation_reason)) BETWEEN 1 AND 2000
    )
);


-- =========================================================
-- 2. SOURCE LIFECYCLE EVENTS
-- =========================================================

CREATE TABLE transfer_request_source_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_source_id UUID NOT NULL,

    transfer_request_item_id UUID NOT NULL
        REFERENCES transfer_request_items(id) ON DELETE RESTRICT,

    event_type TEXT NOT NULL
        CHECK (event_type IN ('created', 'deactivated')),

    source_storage_point_id UUID NOT NULL
        REFERENCES storage_points(id) ON DELETE RESTRICT,

    allocated_quantity INTEGER NOT NULL
        CHECK (allocated_quantity > 0),

    operation_key UUID NOT NULL UNIQUE,

    reason TEXT,

    created_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transfer_request_source_events_item
    ON transfer_request_source_events(
        transfer_request_item_id,
        created_at DESC
    );

CREATE INDEX idx_transfer_request_source_events_source
    ON transfer_request_source_events(
        transfer_request_source_id,
        created_at DESC
    );


-- =========================================================
-- 3. IMMUTABLE SOURCE LIFECYCLE HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_source_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_transfer_request_source_events_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_source_events
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_source_event_mutation();


-- =========================================================
-- 4. SOURCE ALLOCATION TOTAL VALIDATION
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
      AND is_active = TRUE
      AND (
          TG_OP <> 'UPDATE'
          OR id <> OLD.id
      );

    IF TG_OP = 'INSERT' THEN
        v_allocated_quantity :=
            v_allocated_quantity + NEW.allocated_quantity;

    ELSIF TG_OP = 'UPDATE' AND NEW.is_active = TRUE THEN
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


DROP TRIGGER IF EXISTS transfer_request_source_allocation_guard
ON transfer_request_sources;

CREATE TRIGGER transfer_request_source_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_allocation();


-- =========================================================
-- 5. SOURCE POINT VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source_point()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;
    v_point RECORD;
BEGIN
    SELECT
        tr.id,
        tr.status,
        tr.destination_storage_point_id
    INTO v_request
    FROM transfer_request_items tri
    JOIN transfer_requests tr
        ON tr.id = tri.transfer_request_id
    WHERE tri.id = NEW.transfer_request_item_id
    FOR UPDATE OF tri, tr;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_ITEM_NOT_FOUND';
    END IF;

    IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    IF NEW.source_storage_point_id =
       v_request.destination_storage_point_id THEN
        RAISE EXCEPTION 'SOURCE_EQUALS_DESTINATION';
    END IF;

    SELECT id, status
    INTO v_point
    FROM storage_points
    WHERE id = NEW.source_storage_point_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
    END IF;

    IF v_point.status = 'closed' THEN
        RAISE EXCEPTION 'STORAGE_POINT_CLOSED';
    END IF;

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_validate_transfer_request_source_point
BEFORE INSERT OR UPDATE OF
    transfer_request_item_id,
    source_storage_point_id
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_point();


-- =========================================================
-- 6. VALIDATE SOURCE CREATION CONFIRMATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source_creation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.creation_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    PERFORM assert_storage_point_operation_confirmed(
        NEW.source_storage_point_id,
        'transfer_request_source',
        NEW.creation_operation_key
    );

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_transfer_request_source_creation_confirmation
BEFORE INSERT
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_creation();


-- =========================================================
-- 7. ADD TRANSFER REQUEST SOURCE
-- =========================================================

CREATE OR REPLACE FUNCTION add_transfer_request_source(
    p_transfer_request_item_id UUID,
    p_source_storage_point_id UUID,
    p_allocated_quantity INTEGER,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_request RECORD;
    v_source_id UUID;
    v_existing RECORD;
BEGIN
    IF p_allocated_quantity IS NULL OR p_allocated_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'ACTOR_AND_OPERATION_KEY_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_source_events
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.event_type <> 'created'
           OR v_existing.transfer_request_item_id
                <> p_transfer_request_item_id
           OR v_existing.source_storage_point_id
                <> p_source_storage_point_id
           OR v_existing.allocated_quantity <> p_allocated_quantity
           OR v_existing.created_by <> p_user_id
           OR v_existing.reason IS DISTINCT FROM p_reason THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.transfer_request_source_id;
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

    IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM transfer_request_sources
        WHERE transfer_request_item_id = p_transfer_request_item_id
          AND source_storage_point_id = p_source_storage_point_id
          AND is_active = TRUE
    ) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_ALREADY_EXISTS';
    END IF;

    PERFORM assert_storage_point_operation_confirmed(
        p_source_storage_point_id,
        'transfer_request_source',
        p_operation_key
    );

    INSERT INTO transfer_request_sources (
        transfer_request_id,
        transfer_request_item_id,
        source_storage_point_id,
        allocated_quantity,
        created_by,
        creation_operation_key
    )
    VALUES (
        v_item.transfer_request_id,
        p_transfer_request_item_id,
        p_source_storage_point_id,
        p_allocated_quantity,
        p_user_id,
        p_operation_key
    )
    RETURNING id INTO v_source_id;

    INSERT INTO transfer_request_source_events (
        transfer_request_source_id,
        transfer_request_item_id,
        event_type,
        source_storage_point_id,
        allocated_quantity,
        operation_key,
        reason,
        created_by
    )
    VALUES (
        v_source_id,
        p_transfer_request_item_id,
        'created',
        p_source_storage_point_id,
        p_allocated_quantity,
        p_operation_key,
        p_reason,
        p_user_id
    );

    RETURN v_source_id;
END;
$$;


-- =========================================================
-- 8. VALIDATE SOURCE DEACTIVATION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_transfer_request_source_deactivatable(
    p_source_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_active_reserved BIGINT := 0;
    v_loaded BIGINT := 0;
    v_unloaded BIGINT := 0;
    v_received BIGINT := 0;
    v_resolved BIGINT := 0;
    v_unresolved BIGINT := 0;
BEGIN
    SELECT COALESCE(
        SUM(
            reserved_quantity
            - consumed_quantity
            - released_quantity
        ),
        0
    )
    INTO v_active_reserved
    FROM inventory_reservations
    WHERE transfer_request_source_id = p_source_id;

    IF v_active_reserved < 0 THEN
        RAISE EXCEPTION 'INVALID_INVENTORY_RESERVATION_BALANCE';
    END IF;

    IF v_active_reserved > 0 THEN
        RAISE EXCEPTION 'SOURCE_HAS_ACTIVE_RESERVATIONS';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM shipment_items si
        JOIN shipments s ON s.id = si.shipment_id
        WHERE si.transfer_request_source_id = p_source_id
          AND s.status = 'pending'
    ) THEN
        RAISE EXCEPTION 'SOURCE_HAS_PENDING_SHIPMENT_ITEMS';
    END IF;

    SELECT
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type = 'load'
            ),
            0
        ),
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type = 'unload_before_departure'
            ),
            0
        ),
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type = 'receive'
            ),
            0
        ),
        COALESCE(
            SUM(quantity) FILTER (
                WHERE operation_type IN ('return', 'loss', 'writeoff')
            ),
            0
        )
    INTO
        v_loaded,
        v_unloaded,
        v_received,
        v_resolved
    FROM shipment_cargo_operations sco
    JOIN shipment_items si
        ON si.id = sco.shipment_item_id
    WHERE si.transfer_request_source_id = p_source_id;

    v_unresolved :=
        v_loaded
        - v_unloaded
        - v_received
        - v_resolved;

    IF v_unresolved < 0 THEN
        RAISE EXCEPTION 'INVALID_SHIPMENT_CARGO_BALANCE';
    END IF;

    IF v_unresolved > 0 THEN
        RAISE EXCEPTION 'SOURCE_HAS_UNRESOLVED_CARGO';
    END IF;
END;
$$;


-- =========================================================
-- 9. DEACTIVATE TRANSFER REQUEST SOURCE
-- =========================================================

CREATE OR REPLACE FUNCTION delete_transfer_request_source(
    p_source_id UUID,
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
    v_event_id UUID;
BEGIN
    IF p_user_id IS NULL OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'ACTOR_AND_OPERATION_KEY_REQUIRED';
    END IF;

    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'DEACTIVATION_REASON_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_source_events
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.event_type <> 'deactivated'
           OR v_existing.transfer_request_source_id <> p_source_id
           OR v_existing.created_by <> p_user_id
           OR v_existing.reason <> BTRIM(p_reason) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    SELECT *
    INTO v_source
    FROM transfer_request_sources
    WHERE id = p_source_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    IF v_source.is_active = FALSE THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_ALREADY_INACTIVE';
    END IF;

    SELECT *
    INTO v_item
    FROM transfer_request_items
    WHERE id = v_source.transfer_request_item_id
    FOR UPDATE;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = v_item.transfer_request_id
    FOR UPDATE;

    IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    PERFORM assert_transfer_request_source_deactivatable(p_source_id);

    UPDATE transfer_request_sources
    SET
        is_active = FALSE,
        deactivated_by = p_user_id,
        deactivated_at = NOW(),
        deactivation_reason = BTRIM(p_reason),
        updated_at = NOW()
    WHERE id = p_source_id;

    INSERT INTO transfer_request_source_events (
        transfer_request_source_id,
        transfer_request_item_id,
        event_type,
        source_storage_point_id,
        allocated_quantity,
        operation_key,
        reason,
        created_by
    )
    VALUES (
        v_source.id,
        v_source.transfer_request_item_id,
        'deactivated',
        v_source.source_storage_point_id,
        v_source.allocated_quantity,
        p_operation_key,
        BTRIM(p_reason),
        p_user_id
    )
    RETURNING id INTO v_event_id;

    RETURN v_event_id;
END;
$$;


-- =========================================================
-- 10. PREVENT DIRECT SOURCE DELETION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_direct_transfer_request_source_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_DEACTIVATION_REQUIRED';
END;
$$;


CREATE TRIGGER trg_prevent_direct_transfer_request_source_delete
BEFORE DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION prevent_direct_transfer_request_source_delete();


-- =========================================================
-- 11. CONTROLLED SOURCE ALLOCATION UPDATE
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

    IF p_user_id IS NULL OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'ACTOR_AND_OPERATION_KEY_REQUIRED';
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

    SELECT *
    INTO v_source
    FROM transfer_request_sources
    WHERE id = p_source_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_item
    FROM transfer_request_items
    WHERE id = v_source.transfer_request_item_id
    FOR UPDATE;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = v_item.transfer_request_id
    FOR UPDATE;

    SELECT *
    INTO v_source
    FROM transfer_request_sources
    WHERE id = p_source_id
    FOR UPDATE;

    IF v_source.is_active = FALSE THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_INACTIVE';
    END IF;

    IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_EDITABLE';
    END IF;

    IF p_new_quantity = v_source.allocated_quantity THEN
        RAISE EXCEPTION 'QUANTITY_UNCHANGED';
    END IF;

    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_total_other
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_source.transfer_request_item_id
      AND is_active = TRUE
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