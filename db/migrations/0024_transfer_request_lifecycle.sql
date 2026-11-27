-- =========================================================
-- 1. TRANSFER REQUEST STATUS HISTORY
-- =========================================================

CREATE TABLE transfer_request_status_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id) ON DELETE RESTRICT,

    old_status TEXT,

    new_status TEXT NOT NULL,

    reason TEXT,

    changed_by UUID
        REFERENCES users(id) ON DELETE RESTRICT,

    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_transfer_request_status_history_new_status
        CHECK (
            new_status IN (
                'draft',
                'pending',
                'approved',
                'in_progress',
                'fulfilled',
                'partially_fulfilled',
                'cancelled'
            )
        ),

    CONSTRAINT chk_transfer_request_status_history_old_status
        CHECK (
            old_status IS NULL
            OR old_status IN (
                'draft',
                'pending',
                'approved',
                'in_progress',
                'fulfilled',
                'partially_fulfilled',
                'cancelled'
            )
        ),

    CONSTRAINT chk_transfer_request_status_history_reason
        CHECK (
            reason IS NULL
            OR LENGTH(BTRIM(reason)) <= 2000
        )
);


CREATE INDEX idx_transfer_request_status_history_request
    ON transfer_request_status_history(
        transfer_request_id,
        changed_at DESC
    );


-- =========================================================
-- 2. IMMUTABLE STATUS HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_status_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_STATUS_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_transfer_request_status_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_status_history
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_status_history_mutation();


-- =========================================================
-- 3. VALIDATE STATUS TRANSITIONS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status IN (
        'fulfilled',
        'partially_fulfilled',
        'cancelled'
    ) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_TERMINAL_STATUS';
    END IF;

    IF OLD.status = 'draft'
       AND NEW.status NOT IN (
           'pending',
           'cancelled'
       ) THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_STATUS_TRANSITION';
    END IF;

    IF OLD.status = 'pending'
       AND NEW.status NOT IN (
           'approved',
           'draft',
           'cancelled'
       ) THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_STATUS_TRANSITION';
    END IF;

    IF OLD.status = 'approved'
       AND NEW.status NOT IN (
           'in_progress',
           'fulfilled',
           'partially_fulfilled',
           'cancelled'
       ) THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_STATUS_TRANSITION';
    END IF;

    IF OLD.status = 'in_progress'
       AND NEW.status NOT IN (
           'approved',
           'fulfilled',
           'partially_fulfilled',
           'cancelled'
       ) THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_STATUS_TRANSITION';
    END IF;

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_transfer_request_status_transition_guard
BEFORE UPDATE OF status
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_status_transition();


-- =========================================================
-- 4. RECORD STATUS CHANGES
-- =========================================================

CREATE OR REPLACE FUNCTION record_transfer_request_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    INSERT INTO transfer_request_status_history (
        transfer_request_id,
        old_status,
        new_status,
        reason,
        changed_by
    )
    VALUES (
        NEW.id,
        OLD.status,
        NEW.status,
        NULL,
        NULL
    );

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_transfer_request_status_history_insert
AFTER UPDATE OF status
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION record_transfer_request_status_change();


-- =========================================================
-- 5. PREVENT TRANSFER REQUEST DELETION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_DELETION_NOT_ALLOWED';
END;
$$;


CREATE TRIGGER trg_transfer_request_delete_guard
BEFORE DELETE
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_deletion();


-- =========================================================
-- 6. PROTECT SUBMITTED REQUEST FIELDS
-- =========================================================

CREATE OR REPLACE FUNCTION protect_submitted_transfer_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status <> 'draft' THEN
        IF NEW.destination_storage_point_id
           IS DISTINCT FROM OLD.destination_storage_point_id THEN
            RAISE EXCEPTION 'TRANSFER_REQUEST_DESTINATION_IMMUTABLE';
        END IF;

        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            RAISE EXCEPTION 'TRANSFER_REQUEST_CREATOR_IMMUTABLE';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_transfer_request_submitted_fields_guard
BEFORE UPDATE OF
    destination_storage_point_id,
    created_by
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION protect_submitted_transfer_request();