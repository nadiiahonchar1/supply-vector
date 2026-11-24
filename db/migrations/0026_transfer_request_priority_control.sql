-- =========================================================
-- 1. PERMISSIONS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES
  (
    'transfer_request_priority_change',
    'Зміна пріоритету заявки'
  ),
  (
    'transfer_request_urgent_approve',
    'Погодження термінового пріоритету'
  )
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. PRIORITY CHANGE LOG
-- =========================================================

CREATE TABLE transfer_request_priority_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_id UUID NOT NULL
    REFERENCES transfer_requests(id),

  old_priority TEXT NOT NULL,
  new_priority TEXT NOT NULL,

  old_reason TEXT,
  new_reason TEXT,

  changed_by UUID NOT NULL REFERENCES users(id),

  operation_key UUID NOT NULL UNIQUE,

  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT priority_history_old_check
    CHECK (
      old_priority IN ('low', 'normal', 'high', 'urgent')
    ),

  CONSTRAINT priority_history_new_check
    CHECK (
      new_priority IN ('low', 'normal', 'high', 'urgent')
    ),

  CONSTRAINT priority_history_reason_length
    CHECK (
      new_reason IS NULL OR LENGTH(new_reason) <= 2000
    )
);

CREATE INDEX transfer_request_priority_history_request_idx
  ON transfer_request_priority_history(
    transfer_request_id,
    changed_at DESC
  );


-- =========================================================
-- 3. THE CONSTANCY OF THE HISTORY OF PRIORITIES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_priority_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію пріоритетів заявки не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER transfer_request_priority_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_priority_history
FOR EACH ROW
EXECUTE FUNCTION prevent_priority_history_mutation();


-- =========================================================
-- 4. VERIFICATION OF THE RIGHT TO CHANGE PRIORITY
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
    JOIN user_roles ur ON ur.user_id = u.id
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE u.id = p_user_id
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
      AND p.code = 'transfer_request_priority_change'
  );
$$;


-- =========================================================
-- 5. CHANGE OF PRIORITY
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
  v_history_id UUID;
  v_existing_id UUID;
  v_reason TEXT;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_new_priority NOT IN ('low', 'normal', 'high', 'urgent') THEN
    RAISE EXCEPTION 'Некоректний пріоритет заявки';
  END IF;

  v_reason := NULLIF(TRIM(p_new_reason), '');

  IF p_new_priority = 'high'
     AND (
       v_reason IS NULL
       OR LENGTH(v_reason) > 500
     ) THEN
    RAISE EXCEPTION
      'Для високого пріоритету потрібна причина до 500 символів';
  END IF;

  IF p_new_priority = 'urgent'
     AND (
       v_reason IS NULL
       OR LENGTH(v_reason) > 2000
     ) THEN
    RAISE EXCEPTION
      'Для термінового пріоритету потрібна причина до 2000 символів';
  END IF;

  IF p_new_priority IN ('low', 'normal')
     AND v_reason IS NOT NULL THEN
    RAISE EXCEPTION
      'Для низького та звичайного пріоритету причина не передбачена';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_priority_history
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  IF NOT user_can_change_request_priority(p_user_id) THEN
    RAISE EXCEPTION
      'Користувач не має права змінювати пріоритет';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status NOT IN (
    'draft',
    'pending',
    'approved',
    'in_progress'
  ) THEN
    RAISE EXCEPTION
      'Не можна змінювати пріоритет завершеної заявки';
  END IF;

  IF v_request.priority = p_new_priority
     AND v_request.priority_reason IS NOT DISTINCT FROM v_reason THEN
    RAISE EXCEPTION
      'Новий пріоритет збігається з поточним';
  END IF;

  INSERT INTO transfer_request_priority_history (
    transfer_request_id,
    old_priority,
    new_priority,
    old_reason,
    new_reason,
    changed_by,
    operation_key
  )
  VALUES (
    p_transfer_request_id,
    v_request.priority,
    p_new_priority,
    v_request.priority_reason,
    v_reason,
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_history_id;

  UPDATE transfer_requests
  SET priority = p_new_priority,
      priority_reason = v_reason,
      urgent_approval_status =
        CASE
          WHEN p_new_priority = 'urgent' THEN 'pending'
          ELSE 'not_required'
        END,
      updated_at = NOW()
  WHERE id = p_transfer_request_id;

  RETURN v_history_id;
END;
$$;


-- =========================================================
-- 6. VERIFICATION OF THE AUTHORITY TO APPROVE URGENCY
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
    JOIN user_roles ur ON ur.user_id = u.id
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE u.id = p_user_id
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
      AND p.code = 'transfer_request_urgent_approve'
  );
$$;


-- =========================================================
-- 7. URGENCY DECISION LOG
-- =========================================================

CREATE TABLE transfer_request_urgent_priority_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_id UUID NOT NULL
    REFERENCES transfer_requests(id),

  decision TEXT NOT NULL
    CHECK (decision IN ('approved', 'rejected')),

  comment TEXT,

  decided_by UUID NOT NULL REFERENCES users(id),

  operation_key UUID NOT NULL UNIQUE,

  decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT urgent_decision_comment_length
    CHECK (
      comment IS NULL OR LENGTH(comment) <= 2000
    )
);

CREATE INDEX urgent_priority_decisions_request_idx
  ON transfer_request_urgent_priority_decisions(
    transfer_request_id,
    decided_at DESC
  );


CREATE OR REPLACE FUNCTION prevent_urgent_decision_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію погодження терміновості не можна змінювати';
END;
$$;

CREATE TRIGGER urgent_priority_decisions_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_urgent_priority_decisions
FOR EACH ROW
EXECUTE FUNCTION prevent_urgent_decision_mutation();


-- =========================================================
-- 8. APPROVAL OR REJECTION OF URGENCY
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
  v_decision_id UUID;
  v_existing_id UUID;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Некоректне рішення';
  END IF;

  IF p_comment IS NOT NULL
     AND LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION 'Коментар перевищує допустиму довжину';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_urgent_priority_decisions
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  IF NOT user_can_approve_urgent_priority(p_user_id) THEN
    RAISE EXCEPTION
      'Користувач не має права погоджувати терміновість';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.priority <> 'urgent' THEN
    RAISE EXCEPTION
      'Заявка не має термінового пріоритету';
  END IF;

  IF v_request.urgent_approval_status <> 'pending' THEN
    RAISE EXCEPTION
      'Терміновість уже має остаточне рішення';
  END IF;

  IF v_request.created_by = p_user_id THEN
    RAISE EXCEPTION
      'Автор заявки не може погоджувати власну терміновість';
  END IF;

  INSERT INTO transfer_request_urgent_priority_decisions (
    transfer_request_id,
    decision,
    comment,
    decided_by,
    operation_key
  )
  VALUES (
    p_transfer_request_id,
    p_decision,
    p_comment,
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_decision_id;

  UPDATE transfer_requests
  SET urgent_approval_status = p_decision,
      updated_at = NOW()
  WHERE id = p_transfer_request_id;

  RETURN v_decision_id;
END;
$$;