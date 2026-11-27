-- =========================================================
-- 1. APPROVAL PERMISSION
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
    'transfer_request_approve',
    'Approve transfer requests'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. TRANSFER REQUEST APPROVAL HISTORY
-- =========================================================

CREATE TABLE transfer_request_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id) ON DELETE RESTRICT,

    decision TEXT NOT NULL
        CHECK (decision IN ('approved', 'returned')),

    comment TEXT,

    decided_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    operation_key UUID NOT NULL UNIQUE,

    decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_transfer_request_approval_comment
        CHECK (
            comment IS NULL
            OR LENGTH(BTRIM(comment)) <= 2000
        ),

    CONSTRAINT chk_transfer_request_return_comment
        CHECK (
            decision <> 'returned'
            OR NULLIF(BTRIM(comment), '') IS NOT NULL
        )
);


CREATE INDEX idx_transfer_request_approvals_request
    ON transfer_request_approvals(
        transfer_request_id,
        decided_at DESC
    );


-- =========================================================
-- 3. IMMUTABLE APPROVAL HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_approval_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRANSFER_REQUEST_APPROVAL_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_transfer_request_approvals_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_approval_mutation();


-- =========================================================
-- 4. CHECK APPROVAL PERMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION user_can_approve_transfer_request(
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM users u
        JOIN user_roles ur
            ON ur.user_id = u.id
        JOIN role_permissions rp
            ON rp.role_id = ur.role_id
        JOIN permissions p
            ON p.id = rp.permission_id
        WHERE u.id = p_user_id
          AND u.is_active = TRUE
          AND u.deleted_at IS NULL
          AND p.code = 'transfer_request_approve'
    );
$$;


-- =========================================================
-- 5. VALIDATE REQUEST BEFORE APPROVAL
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_for_approval(
    p_transfer_request_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_item_count
    FROM transfer_request_items
    WHERE transfer_request_id = p_transfer_request_id;

    IF v_item_count = 0 THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_HAS_NO_ITEMS';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM transfer_request_items tri
        LEFT JOIN LATERAL (
            SELECT COALESCE(SUM(trs.allocated_quantity), 0) AS allocated
            FROM transfer_request_sources trs
            WHERE trs.transfer_request_item_id = tri.id
              AND trs.is_active = TRUE
        ) allocation ON TRUE
        WHERE tri.transfer_request_id = p_transfer_request_id
          AND allocation.allocated <> (
              tri.requested_quantity - tri.cancelled_quantity
          )
    ) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_SOURCE_ALLOCATION_INCOMPLETE';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM transfer_request_sources trs
        JOIN transfer_request_items tri
            ON tri.id = trs.transfer_request_item_id
        JOIN inventory_reservations ir
            ON ir.transfer_request_source_id = trs.id
        WHERE tri.transfer_request_id = p_transfer_request_id
          AND trs.is_active = FALSE
          AND (
              ir.reserved_quantity
              - ir.consumed_quantity
              - ir.released_quantity
          ) > 0
    ) THEN
        RAISE EXCEPTION 'INACTIVE_SOURCE_HAS_ACTIVE_RESERVATIONS';
    END IF;
END;
$$;


-- =========================================================
-- 6. APPROVE TRANSFER REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION approve_transfer_request(
    p_transfer_request_id UUID,
    p_user_id UUID,
    p_operation_key UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;
    v_existing RECORD;
    v_approval_id UUID;
BEGIN
    IF p_transfer_request_id IS NULL
       OR p_user_id IS NULL
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'REQUIRED_APPROVAL_ARGUMENT_MISSING';
    END IF;

    IF p_comment IS NOT NULL
       AND LENGTH(BTRIM(p_comment)) > 2000 THEN
        RAISE EXCEPTION 'APPROVAL_COMMENT_TOO_LONG';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_approvals
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_id <> p_transfer_request_id
           OR v_existing.decision <> 'approved'
           OR v_existing.decided_by <> p_user_id
           OR v_existing.comment IS DISTINCT FROM NULLIF(BTRIM(p_comment), '') THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    IF NOT user_can_approve_transfer_request(p_user_id) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_APPROVAL_FORBIDDEN';
    END IF;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = p_transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_PENDING';
    END IF;

    IF v_request.created_by = p_user_id THEN
        RAISE EXCEPTION 'REQUEST_CREATOR_CANNOT_APPROVE_OWN_REQUEST';
    END IF;

    IF v_request.priority = 'urgent'
       AND v_request.urgent_approval_status <> 'approved' THEN
        RAISE EXCEPTION 'URGENT_PRIORITY_APPROVAL_REQUIRED';
    END IF;

    PERFORM validate_transfer_request_for_approval(
        p_transfer_request_id
    );

    INSERT INTO transfer_request_approvals (
        transfer_request_id,
        decision,
        comment,
        decided_by,
        operation_key
    )
    VALUES (
        p_transfer_request_id,
        'approved',
        NULLIF(BTRIM(p_comment), ''),
        p_user_id,
        p_operation_key
    )
    RETURNING id INTO v_approval_id;

    UPDATE transfer_requests
    SET
        status = 'approved',
        approved_at = NOW(),
        updated_at = NOW()
    WHERE id = p_transfer_request_id;

    RETURN v_approval_id;
END;
$$;


-- =========================================================
-- 7. RETURN TRANSFER REQUEST FOR REVISION
-- =========================================================

CREATE OR REPLACE FUNCTION return_transfer_request_for_revision(
    p_transfer_request_id UUID,
    p_user_id UUID,
    p_operation_key UUID,
    p_comment TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;
    v_existing RECORD;
    v_approval_id UUID;
BEGIN
    IF p_transfer_request_id IS NULL
       OR p_user_id IS NULL
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'REQUIRED_APPROVAL_ARGUMENT_MISSING';
    END IF;

    IF NULLIF(BTRIM(p_comment), '') IS NULL THEN
        RAISE EXCEPTION 'RETURN_COMMENT_REQUIRED';
    END IF;

    IF LENGTH(BTRIM(p_comment)) > 2000 THEN
        RAISE EXCEPTION 'APPROVAL_COMMENT_TOO_LONG';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_approvals
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_id <> p_transfer_request_id
           OR v_existing.decision <> 'returned'
           OR v_existing.decided_by <> p_user_id
           OR v_existing.comment <> BTRIM(p_comment) THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    IF NOT user_can_approve_transfer_request(p_user_id) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_APPROVAL_FORBIDDEN';
    END IF;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = p_transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_PENDING';
    END IF;

    IF v_request.created_by = p_user_id THEN
        RAISE EXCEPTION 'REQUEST_CREATOR_CANNOT_RETURN_OWN_REQUEST';
    END IF;

    INSERT INTO transfer_request_approvals (
        transfer_request_id,
        decision,
        comment,
        decided_by,
        operation_key
    )
    VALUES (
        p_transfer_request_id,
        'returned',
        BTRIM(p_comment),
        p_user_id,
        p_operation_key
    )
    RETURNING id INTO v_approval_id;

    UPDATE transfer_requests
    SET
        status = 'draft',
        submitted_at = NULL,
        updated_at = NOW()
    WHERE id = p_transfer_request_id;

    RETURN v_approval_id;
END;
$$;