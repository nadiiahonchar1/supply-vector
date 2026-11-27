-- =========================================================
-- 1. PRIORITY PERMISSIONS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES
    (
        'transfer_request_priority_change',
        'Change transfer request priority'
    ),
    (
        'transfer_request_urgent_approve',
        'Approve urgent transfer request priority'
    )
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. EXTEND PRIORITY HISTORY
-- =========================================================

ALTER TABLE transfer_request_priority_history
    ADD COLUMN IF NOT EXISTS old_reason TEXT,
    ADD COLUMN IF NOT EXISTS new_reason TEXT,
    ADD COLUMN IF NOT EXISTS operation_key UUID;


CREATE UNIQUE INDEX IF NOT EXISTS
    idx_transfer_request_priority_history_operation_key
ON transfer_request_priority_history(operation_key)
WHERE operation_key IS NOT NULL;


CREATE INDEX IF NOT EXISTS
    idx_transfer_request_priority_history_request
ON transfer_request_priority_history(
    transfer_request_id,
    changed_at DESC
);


-- =========================================================
-- 3. EXTEND URGENT PRIORITY APPROVAL HISTORY
-- =========================================================

ALTER TABLE transfer_request_urgent_approvals
    ADD COLUMN IF NOT EXISTS operation_key UUID;


CREATE UNIQUE INDEX IF NOT EXISTS
    idx_transfer_request_urgent_approvals_operation_key
ON transfer_request_urgent_approvals(operation_key)
WHERE operation_key IS NOT NULL;


-- =========================================================
-- 4. CHECK PRIORITY CHANGE PERMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION user_can_change_request_priority(
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
          AND p.code = 'transfer_request_priority_change'
    );
$$;


-- =========================================================
-- 5. CHANGE TRANSFER REQUEST PRIORITY
-- =========================================================

CREATE OR REPLACE FUNCTION change_transfer_request_priority(
    p_transfer_request_id UUID,
    p_new_priority TEXT,
    p_new_reason TEXT,
    p_user_id UUID,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;
    v_existing RECORD;
    v_history_id UUID;
    v_reason TEXT;
    v_urgent_status TEXT;
BEGIN
    IF p_transfer_request_id IS NULL
       OR p_user_id IS NULL
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'REQUIRED_PRIORITY_ARGUMENT_MISSING';
    END IF;

    IF p_new_priority IS NULL
       OR p_new_priority NOT IN (
           'low',
           'normal',
           'high',
           'urgent'
       ) THEN
        RAISE EXCEPTION 'INVALID_TRANSFER_REQUEST_PRIORITY';
    END IF;

    v_reason := NULLIF(BTRIM(p_new_reason), '');

    IF p_new_priority = 'high'
       AND (
           v_reason IS NULL
           OR LENGTH(v_reason) > 500
       ) THEN
        RAISE EXCEPTION 'HIGH_PRIORITY_REASON_REQUIRED';
    END IF;

    IF p_new_priority = 'urgent'
       AND (
           v_reason IS NULL
           OR LENGTH(v_reason) > 2000
       ) THEN
        RAISE EXCEPTION 'URGENT_PRIORITY_REASON_REQUIRED';
    END IF;

    IF p_new_priority IN ('low', 'normal')
       AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'REASON_NOT_ALLOWED_FOR_PRIORITY';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_priority_history
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_id <> p_transfer_request_id
           OR v_existing.changed_by <> p_user_id
           OR v_existing.new_priority <> p_new_priority
           OR v_existing.new_reason IS DISTINCT FROM v_reason THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    IF NOT user_can_change_request_priority(p_user_id) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_PRIORITY_CHANGE_FORBIDDEN';
    END IF;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = p_transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status NOT IN (
        'draft',
        'pending',
        'approved',
        'in_progress'
    ) THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_PRIORITY_CHANGE_NOT_ALLOWED';
    END IF;

    IF v_request.priority = p_new_priority
       AND v_request.priority_reason IS NOT DISTINCT FROM v_reason THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_PRIORITY_UNCHANGED';
    END IF;

    v_urgent_status :=
        CASE
            WHEN p_new_priority = 'urgent' THEN 'pending'
            ELSE 'not_required'
        END;

    INSERT INTO transfer_request_priority_history (
        transfer_request_id,
        old_priority,
        new_priority,
        reason,
        old_reason,
        new_reason,
        changed_by,
        operation_key
    )
    VALUES (
        p_transfer_request_id,
        v_request.priority,
        p_new_priority,
        v_reason,
        v_request.priority_reason,
        v_reason,
        p_user_id,
        p_operation_key
    )
    RETURNING id INTO v_history_id;

    UPDATE transfer_requests
    SET
        priority = p_new_priority,
        priority_reason = v_reason,
        urgent_approval_status = v_urgent_status,
        updated_at = NOW()
    WHERE id = p_transfer_request_id;

    RETURN v_history_id;
END;
$$;


-- =========================================================
-- 6. CHECK URGENT PRIORITY APPROVAL PERMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION user_can_approve_urgent_priority(
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
          AND p.code = 'transfer_request_urgent_approve'
    );
$$;


-- =========================================================
-- 7. APPROVE OR REJECT URGENT PRIORITY
-- =========================================================

CREATE OR REPLACE FUNCTION decide_transfer_request_urgent_priority(
    p_transfer_request_id UUID,
    p_user_id UUID,
    p_decision TEXT,
    p_comment TEXT,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;
    v_existing RECORD;
    v_decision_id UUID;
    v_comment TEXT;
BEGIN
    IF p_transfer_request_id IS NULL
       OR p_user_id IS NULL
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'REQUIRED_URGENT_APPROVAL_ARGUMENT_MISSING';
    END IF;

    IF p_decision IS NULL
       OR p_decision NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'INVALID_URGENT_PRIORITY_DECISION';
    END IF;

    v_comment := NULLIF(BTRIM(p_comment), '');

    IF v_comment IS NOT NULL
       AND LENGTH(v_comment) > 2000 THEN
        RAISE EXCEPTION 'URGENT_APPROVAL_COMMENT_TOO_LONG';
    END IF;

    IF p_decision = 'rejected'
       AND v_comment IS NULL THEN
        RAISE EXCEPTION 'URGENT_REJECTION_COMMENT_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM transfer_request_urgent_approvals
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.transfer_request_id <> p_transfer_request_id
           OR v_existing.decided_by <> p_user_id
           OR v_existing.decision <> p_decision
           OR v_existing.comment IS DISTINCT FROM v_comment THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    IF NOT user_can_approve_urgent_priority(p_user_id) THEN
        RAISE EXCEPTION 'URGENT_PRIORITY_APPROVAL_FORBIDDEN';
    END IF;

    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = p_transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.priority <> 'urgent' THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_IS_NOT_URGENT';
    END IF;

    IF v_request.urgent_approval_status <> 'pending' THEN
        RAISE EXCEPTION 'URGENT_PRIORITY_ALREADY_DECIDED';
    END IF;

    IF v_request.created_by = p_user_id THEN
        RAISE EXCEPTION 'REQUEST_CREATOR_CANNOT_APPROVE_OWN_URGENCY';
    END IF;

    INSERT INTO transfer_request_urgent_approvals (
        transfer_request_id,
        decision,
        comment,
        decided_by,
        operation_key
    )
    VALUES (
        p_transfer_request_id,
        p_decision,
        v_comment,
        p_user_id,
        p_operation_key
    )
    RETURNING id INTO v_decision_id;

    UPDATE transfer_requests
    SET
        urgent_approval_status = p_decision,
        updated_at = NOW()
    WHERE id = p_transfer_request_id;

    RETURN v_decision_id;
END;
$$;