-- =========================================================
-- 1. AUTHORIZATION TO APPROVE APPLICATIONS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'transfer_request_approve',
  'Погодження заявок на переміщення'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. LOG OF APPROVAL DECISIONS
-- =========================================================

CREATE TABLE transfer_request_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_id UUID NOT NULL
    REFERENCES transfer_requests(id),

  decision TEXT NOT NULL
    CHECK (decision IN ('approved', 'returned')),

  comment TEXT,

  decided_by UUID NOT NULL
    REFERENCES users(id),

  decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  operation_key UUID NOT NULL UNIQUE,

  CONSTRAINT transfer_request_approval_comment_length
    CHECK (
      comment IS NULL
      OR LENGTH(comment) <= 2000
    )
);

CREATE INDEX transfer_request_approvals_request_idx
  ON transfer_request_approvals(
    transfer_request_id,
    decided_at DESC
  );


-- =========================================================
-- 3. PROTECTION OF THE DECISIONS LOG
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_approval_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історія погодження заявки є незмінною';
END;
$$;

CREATE TRIGGER transfer_request_approvals_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_approval_mutation();


-- =========================================================
-- 4. VERIFICATION OF APPROVAL AUTHORITY
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
-- 5. APPROVAL OF THE APPLICATION
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
  v_approval_id UUID;
  v_existing_id UUID;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_comment IS NOT NULL
     AND LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION 'Коментар перевищує допустиму довжину';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_approvals
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  IF NOT user_can_approve_transfer_request(p_user_id) THEN
    RAISE EXCEPTION
      'Користувач не має права погоджувати заявки';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION
      'Погоджувати можна лише заявки зі статусом pending';
  END IF;

  IF v_request.created_by = p_user_id THEN
    RAISE EXCEPTION
      'Автор заявки не може погоджувати власну заявку';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM transfer_request_items
    WHERE transfer_request_id = p_transfer_request_id
  ) THEN
    RAISE EXCEPTION
      'Не можна погодити заявку без товарних позицій';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM transfer_request_items tri
    WHERE tri.transfer_request_id = p_transfer_request_id
      AND (
        SELECT COALESCE(SUM(trs.allocated_quantity), 0)
        FROM transfer_request_sources trs
        WHERE trs.transfer_request_item_id = tri.id
      ) > tri.requested_quantity
  ) THEN
    RAISE EXCEPTION
      'Розподіл товару перевищує потребу заявки';
  END IF;

  PERFORM set_config(
    'app.current_user_id',
    p_user_id::TEXT,
    TRUE
  );

  PERFORM set_config(
    'app.status_change_reason',
    'Заявку погоджено уповноваженою особою',
    TRUE
  );

  UPDATE transfer_requests
  SET status = 'approved',
      updated_at = NOW()
  WHERE id = p_transfer_request_id;

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
    p_comment,
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_approval_id;

  RETURN v_approval_id;
END;
$$;


-- =========================================================
-- 6. RETURN OF APPLICATION FOR REVISION
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
  v_approval_id UUID;
  v_existing_id UUID;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF NULLIF(TRIM(p_comment), '') IS NULL THEN
    RAISE EXCEPTION
      'Необхідно вказати причину повернення на доопрацювання';
  END IF;

  IF LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION 'Коментар перевищує допустиму довжину';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_approvals
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  IF NOT user_can_approve_transfer_request(p_user_id) THEN
    RAISE EXCEPTION
      'Користувач не має права повертати заявки на доопрацювання';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION
      'Повернути на доопрацювання можна лише заявку зі статусом pending';
  END IF;

  IF v_request.created_by = p_user_id THEN
    RAISE EXCEPTION
      'Автор заявки не може самостійно повертати її на доопрацювання';
  END IF;

  PERFORM set_config(
    'app.current_user_id',
    p_user_id::TEXT,
    TRUE
  );

  PERFORM set_config(
    'app.status_change_reason',
    TRIM(p_comment),
    TRUE
  );

  UPDATE transfer_requests
  SET status = 'draft',
      updated_at = NOW()
  WHERE id = p_transfer_request_id;

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
    TRIM(p_comment),
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_approval_id;

  RETURN v_approval_id;
END;
$$;