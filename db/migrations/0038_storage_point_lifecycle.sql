-- =========================================================
-- 1. STORAGE POINT CLOSURE CYCLES
-- =========================================================

CREATE TABLE storage_point_closure_cycles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  closed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  closed_by UUID
    REFERENCES users(id) ON DELETE RESTRICT,

  reopened_at TIMESTAMPTZ,

  reopened_by UUID
    REFERENCES users(id) ON DELETE RESTRICT,

  closure_reason TEXT,

  reopening_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT closure_cycle_reopening_check
    CHECK (
      (reopened_at IS NULL AND reopened_by IS NULL)
      OR
      (reopened_at IS NOT NULL AND reopened_by IS NOT NULL)
    ),

  CONSTRAINT closure_cycle_reopening_after_closing
    CHECK (
      reopened_at IS NULL
      OR reopened_at >= closed_at
    ),

  CONSTRAINT closure_cycle_reason_check
    CHECK (
      closure_reason IS NULL
      OR LENGTH(closure_reason) <= 2000
    ),

  CONSTRAINT closure_cycle_reopening_reason_check
    CHECK (
      reopening_reason IS NULL
      OR LENGTH(reopening_reason) <= 2000
    )
);

CREATE UNIQUE INDEX storage_point_one_open_closure_cycle_idx
  ON storage_point_closure_cycles(storage_point_id)
  WHERE reopened_at IS NULL;

CREATE INDEX storage_point_closure_cycles_history_idx
  ON storage_point_closure_cycles(
    storage_point_id,
    closed_at DESC
  );


-- =========================================================
-- 2. MIGRATE EXISTING CLOSURE HISTORY
-- =========================================================

INSERT INTO storage_point_closure_cycles (
  id,
  storage_point_id,
  closed_at,
  closed_by,
  reopened_at,
  reopened_by,
  closure_reason,
  reopening_reason,
  created_at
)
SELECT
  sc.id,
  sc.storage_point_id,
  sc.closed_at,
  sc.closed_by,
  sc.reopened_at,
  sc.reopened_by,
  sc.closure_reason,
  sc.reopening_reason,
  sc.created_at
FROM storage_point_closures sc
ON CONFLICT (id) DO NOTHING;


-- =========================================================
-- 3. EXTEND CLOSURE BLOCKS
-- =========================================================

ALTER TABLE storage_point_closure_blocks
  ADD COLUMN closure_cycle_id UUID
    REFERENCES storage_point_closure_cycles(id)
    ON DELETE RESTRICT;

ALTER TABLE storage_point_closure_blocks
  ADD COLUMN storage_point_id UUID
    REFERENCES storage_points(id)
    ON DELETE RESTRICT;

ALTER TABLE storage_point_closure_blocks
  ADD COLUMN created_at TIMESTAMPTZ
    NOT NULL DEFAULT NOW();


-- =========================================================
-- 4. MIGRATE CLOSURE BLOCK REFERENCES
-- =========================================================

UPDATE storage_point_closure_blocks cb
SET
  closure_cycle_id = sc.id,
  storage_point_id = sc.storage_point_id,
  created_at = sc.closed_at
FROM storage_point_closures sc
WHERE sc.id = cb.closure_id
  AND (
    cb.closure_cycle_id IS NULL
    OR cb.storage_point_id IS NULL
  );


-- =========================================================
-- 5. VERIFY MIGRATED CLOSURE BLOCK REFERENCES
-- =========================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM storage_point_closure_blocks
    WHERE closure_cycle_id IS NULL
       OR storage_point_id IS NULL
  ) THEN
    RAISE EXCEPTION
      'CLOSURE_BLOCK_MIGRATION_INCOMPLETE';
  END IF;
END;
$$;

ALTER TABLE storage_point_closure_blocks
  ALTER COLUMN closure_cycle_id SET NOT NULL;

ALTER TABLE storage_point_closure_blocks
  ALTER COLUMN storage_point_id SET NOT NULL;


-- =========================================================
-- 6. CLOSURE CYCLE PRODUCT UNIQUENESS
-- =========================================================

CREATE UNIQUE INDEX storage_point_closure_cycle_product_idx
  ON storage_point_closure_blocks(
    closure_cycle_id,
    product_id
  );


-- =========================================================
-- 7. AUTOMATIC CYCLE ASSIGNMENT
-- =========================================================

CREATE OR REPLACE FUNCTION assign_closure_cycle_to_block()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_cycle RECORD;
BEGIN
  IF NEW.closure_cycle_id IS NULL THEN
    SELECT
      id,
      storage_point_id
    INTO v_cycle
    FROM storage_point_closure_cycles
    WHERE storage_point_id = NEW.storage_point_id
      AND reopened_at IS NULL
    ORDER BY closed_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'ACTIVE_CLOSURE_CYCLE_NOT_FOUND';
    END IF;

    NEW.closure_cycle_id := v_cycle.id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles
    WHERE id = NEW.closure_cycle_id
      AND storage_point_id = NEW.storage_point_id
      AND reopened_at IS NULL
  ) THEN
    RAISE EXCEPTION 'INVALID_ACTIVE_CLOSURE_CYCLE';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_block_cycle_guard
BEFORE INSERT
ON storage_point_closure_blocks
FOR EACH ROW
EXECUTE FUNCTION assign_closure_cycle_to_block();


-- =========================================================
-- 8. STORAGE POINT STATUS HISTORY
-- =========================================================

CREATE TABLE storage_point_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  old_status TEXT NOT NULL,

  new_status TEXT NOT NULL,

  changed_by UUID
    REFERENCES users(id) ON DELETE RESTRICT,

  reason TEXT,

  closure_cycle_id UUID
    REFERENCES storage_point_closure_cycles(id)
    ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT storage_point_status_history_status_check
    CHECK (
      old_status IN ('active', 'unavailable', 'closed')
      AND new_status IN ('active', 'unavailable', 'closed')
      AND old_status <> new_status
    ),

  CONSTRAINT storage_point_status_history_reason_check
    CHECK (
      reason IS NULL OR LENGTH(reason) <= 2000
    )
);

CREATE INDEX storage_point_status_history_point_idx
  ON storage_point_status_history(
    storage_point_id,
    created_at DESC
  );


-- =========================================================
-- 9. IMMUTABLE STATUS HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_storage_point_status_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'STORAGE_POINT_STATUS_HISTORY_IMMUTABLE';
END;
$$;

CREATE TRIGGER storage_point_status_history_immutable
BEFORE UPDATE OR DELETE
ON storage_point_status_history
FOR EACH ROW
EXECUTE FUNCTION prevent_storage_point_status_history_mutation();


-- =========================================================
-- 10. PREVENT RECLOSING WITH UNRELEASED BLOCKS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closure_with_unreleased_blocks()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'closed'
     AND OLD.status <> 'closed' THEN

    IF EXISTS (
      SELECT 1
      FROM storage_point_closure_blocks cb
      JOIN storage_point_closure_cycles cc
        ON cc.id = cb.closure_cycle_id
      WHERE cb.storage_point_id = NEW.id
        AND cc.reopened_at IS NOT NULL
        AND cb.initial_quantity > cb.released_quantity
    ) THEN
      RAISE EXCEPTION
        'PREVIOUS_CLOSURE_BLOCKS_REMAIN_UNRELEASED';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_reopen_guard
BEFORE UPDATE OF status
ON storage_points
FOR EACH ROW
EXECUTE FUNCTION prevent_closure_with_unreleased_blocks();


-- =========================================================
-- 11. REOPENING PERMISSION
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'storage_point_reopen',
  'Reopen closed storage point'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 12. REOPEN STORAGE POINT
-- =========================================================

CREATE OR REPLACE FUNCTION reopen_storage_point(
  p_storage_point_id UUID,
  p_user_id UUID,
  p_new_status TEXT,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_cycle_id UUID;
  v_old_status TEXT;
BEGIN
  IF p_storage_point_id IS NULL
     OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_REOPEN_ARGUMENTS';
  END IF;

  IF p_new_status NOT IN ('active', 'unavailable') THEN
    RAISE EXCEPTION 'INVALID_REOPEN_STATUS';
  END IF;

  IF p_reason IS NULL
     OR BTRIM(p_reason) = ''
     OR LENGTH(p_reason) > 2000 THEN
    RAISE EXCEPTION 'REOPEN_REASON_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ACTIVE_USER_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp
      ON rp.role_id = ur.role_id
    JOIN permissions p
      ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = 'storage_point_reopen'
  ) THEN
    RAISE EXCEPTION 'STORAGE_POINT_REOPEN_PERMISSION_REQUIRED';
  END IF;

  SELECT status
  INTO v_old_status
  FROM storage_points
  WHERE id = p_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
  END IF;

  IF v_old_status <> 'closed' THEN
    RAISE EXCEPTION 'STORAGE_POINT_NOT_CLOSED';
  END IF;

  SELECT id
  INTO v_cycle_id
  FROM storage_point_closure_cycles
  WHERE storage_point_id = p_storage_point_id
    AND reopened_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACTIVE_CLOSURE_CYCLE_NOT_FOUND';
  END IF;

  UPDATE storage_point_closure_cycles
  SET
    reopened_at = NOW(),
    reopened_by = p_user_id,
    reopening_reason = BTRIM(p_reason)
  WHERE id = v_cycle_id;

  UPDATE storage_point_closures
  SET
    reopened_at = NOW(),
    reopened_by = p_user_id,
    reopening_reason = BTRIM(p_reason)
  WHERE id = v_cycle_id
    AND reopened_at IS NULL;

  UPDATE storage_points
  SET
    status = p_new_status,
    updated_at = NOW()
  WHERE id = p_storage_point_id;

  INSERT INTO storage_point_status_history (
    storage_point_id,
    old_status,
    new_status,
    changed_by,
    reason,
    closure_cycle_id
  )
  VALUES (
    p_storage_point_id,
    v_old_status,
    p_new_status,
    p_user_id,
    BTRIM(p_reason),
    v_cycle_id
  );

  RETURN v_cycle_id;
END;
$$;


-- =========================================================
-- 13. CLOSURE BLOCK REMAINING QUANTITY
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_remaining AS
SELECT
  cb.id AS closure_block_id,
  cb.closure_id,
  cb.closure_cycle_id,
  cb.storage_point_id,
  sp.name AS storage_point_name,

  cb.inventory_id,
  cb.product_id,
  p.sku,
  p.name AS product_name,

  cb.initial_quantity,
  cb.released_quantity,

  (
    cb.initial_quantity - cb.released_quantity
  ) AS remaining_closure_block_quantity,

  cc.closed_at,
  cc.reopened_at,

  sp.status AS current_storage_point_status

FROM storage_point_closure_blocks cb

JOIN storage_point_closure_cycles cc
  ON cc.id = cb.closure_cycle_id

JOIN storage_points sp
  ON sp.id = cb.storage_point_id

JOIN products p
  ON p.id = cb.product_id

WHERE cb.initial_quantity > cb.released_quantity;