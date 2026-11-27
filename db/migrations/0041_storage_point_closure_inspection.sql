-- =========================================================
-- 1. EXTEND CLOSURE INSPECTION RECORDS
-- =========================================================

ALTER TABLE storage_point_closure_inspections
  ADD COLUMN IF NOT EXISTS closure_cycle_id UUID
    REFERENCES storage_point_closure_cycles(id)
    ON DELETE RESTRICT;

UPDATE storage_point_closure_inspections i
SET closure_cycle_id = b.closure_cycle_id
FROM storage_point_closure_blocks b
WHERE b.id = i.closure_block_id
  AND i.closure_cycle_id IS NULL;

ALTER TABLE storage_point_closure_inspections
  ALTER COLUMN closure_cycle_id SET NOT NULL;

ALTER TABLE storage_point_closure_inspections
  ADD COLUMN IF NOT EXISTS unsuitable_quantity INTEGER
    GENERATED ALWAYS AS (
      inspected_quantity - suitable_quantity
    ) STORED;

ALTER TABLE storage_point_closure_inspections
  ADD CONSTRAINT closure_inspection_comment_length_check
  CHECK (
    comment IS NULL OR LENGTH(comment) <= 2000
  );


-- =========================================================
-- 2. INSPECTION INDEXES
-- =========================================================

CREATE INDEX IF NOT EXISTS storage_point_closure_inspections_block_idx
  ON storage_point_closure_inspections(
    closure_block_id,
    inspected_at DESC
  );

CREATE INDEX IF NOT EXISTS storage_point_closure_inspections_cycle_idx
  ON storage_point_closure_inspections(
    closure_cycle_id,
    inspected_at DESC
  );

CREATE INDEX IF NOT EXISTS storage_point_closure_inspections_employee_idx
  ON storage_point_closure_inspections(
    inspected_by,
    inspected_at DESC
  );


-- =========================================================
-- 3. VALIDATE CLOSURE INSPECTION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_closure_inspection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_cycle RECORD;
  v_inspected_total BIGINT;
  v_is_responsible BOOLEAN;
BEGIN
  SELECT
    b.id,
    b.storage_point_id,
    b.product_id,
    b.closure_cycle_id,
    b.initial_quantity,
    b.released_quantity
  INTO v_block
  FROM storage_point_closure_blocks b
  WHERE b.id = NEW.closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_BLOCK_NOT_FOUND';
  END IF;

  SELECT
    c.id,
    c.storage_point_id,
    c.reopened_at
  INTO v_cycle
  FROM storage_point_closure_cycles c
  WHERE c.id = NEW.closure_cycle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_NOT_FOUND';
  END IF;

  IF v_block.closure_cycle_id <> NEW.closure_cycle_id
     OR v_block.storage_point_id <> v_cycle.storage_point_id THEN
    RAISE EXCEPTION 'CLOSURE_INSPECTION_REFERENCE_MISMATCH';
  END IF;

  IF v_cycle.reopened_at IS NOT NULL THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_ALREADY_REOPENED';
  END IF;

  IF NEW.inspected_quantity IS NULL
     OR NEW.inspected_quantity <= 0
     OR NEW.suitable_quantity IS NULL
     OR NEW.suitable_quantity < 0
     OR NEW.suitable_quantity > NEW.inspected_quantity THEN
    RAISE EXCEPTION 'INVALID_CLOSURE_INSPECTION_QUANTITIES';
  END IF;

  IF NEW.inspected_by IS NULL THEN
    RAISE EXCEPTION 'INSPECTOR_REQUIRED';
  END IF;

  IF NEW.comment IS NOT NULL
     AND LENGTH(NEW.comment) > 2000 THEN
    RAISE EXCEPTION 'INSPECTION_COMMENT_TOO_LONG';
  END IF;

  IF NEW.inspected_quantity >
     v_block.initial_quantity - v_block.released_quantity THEN
    RAISE EXCEPTION 'INSPECTION_EXCEEDS_REMAINING_BLOCK';
  END IF;

  SELECT COALESCE(SUM(i.inspected_quantity), 0)
  INTO v_inspected_total
  FROM storage_point_closure_inspections i
  WHERE i.closure_block_id = NEW.closure_block_id;

  IF v_inspected_total + NEW.inspected_quantity >
     v_block.initial_quantity - v_block.released_quantity THEN
    RAISE EXCEPTION 'INSPECTION_TOTAL_EXCEEDS_REMAINING_BLOCK';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM storage_point_responsibles spr
    JOIN employees e
      ON e.id = spr.employee_id
    WHERE spr.storage_point_id = v_block.storage_point_id
      AND spr.employee_id = NEW.inspected_by
      AND spr.valid_from <= CURRENT_DATE
      AND (
        spr.valid_until IS NULL
        OR spr.valid_until >= CURRENT_DATE
      )
      AND e.is_active = TRUE
  )
  INTO v_is_responsible;

  IF NOT v_is_responsible THEN
    RAISE EXCEPTION 'ACTIVE_STORAGE_POINT_RESPONSIBLE_REQUIRED';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS storage_point_closure_inspection_guard
ON storage_point_closure_inspections;

CREATE TRIGGER storage_point_closure_inspection_guard
BEFORE INSERT
ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION validate_closure_inspection();


-- =========================================================
-- 4. INSPECTION HISTORY IMMUTABILITY
-- =========================================================

DROP TRIGGER IF EXISTS storage_point_closure_inspection_immutable
ON storage_point_closure_inspections;

DROP TRIGGER IF EXISTS trg_storage_point_closure_inspections_immutable
ON storage_point_closure_inspections;

DROP TRIGGER IF EXISTS storage_point_closure_inspections_immutable
ON storage_point_closure_inspections;

CREATE TRIGGER storage_point_closure_inspections_immutable
BEFORE UPDATE OR DELETE
ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 5. CREATE CLOSURE INSPECTION
-- =========================================================

CREATE OR REPLACE FUNCTION inspect_storage_point_closure_stock(
  p_closure_block_id UUID,
  p_inspected_quantity INTEGER,
  p_suitable_quantity INTEGER,
  p_employee_id UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_inspection_id UUID;
BEGIN
  IF p_closure_block_id IS NULL
     OR p_employee_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_INSPECTION_ARGUMENTS';
  END IF;

  INSERT INTO storage_point_closure_inspections (
    closure_block_id,
    closure_cycle_id,
    inspected_quantity,
    suitable_quantity,
    inspected_by,
    comment
  )
  SELECT
    b.id,
    b.closure_cycle_id,
    p_inspected_quantity,
    p_suitable_quantity,
    p_employee_id,
    p_comment
  FROM storage_point_closure_blocks b
  WHERE b.id = p_closure_block_id
  RETURNING id INTO v_inspection_id;

  IF v_inspection_id IS NULL THEN
    RAISE EXCEPTION 'CLOSURE_BLOCK_NOT_FOUND';
  END IF;

  RETURN v_inspection_id;
END;
$$;


-- =========================================================
-- 6. REQUIRE COMPLETE INSPECTION BEFORE REOPENING
-- =========================================================

CREATE OR REPLACE FUNCTION assert_storage_point_closure_inspected(
  p_storage_point_id UUID,
  p_closure_cycle_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_uninspected_count BIGINT;
BEGIN
  SELECT COUNT(*)
  INTO v_uninspected_count
  FROM storage_point_closure_blocks b
  WHERE b.storage_point_id = p_storage_point_id
    AND b.closure_cycle_id = p_closure_cycle_id
    AND b.initial_quantity > b.released_quantity
    AND (
      SELECT COALESCE(SUM(i.inspected_quantity), 0)
      FROM storage_point_closure_inspections i
      WHERE i.closure_block_id = b.id
    ) < b.initial_quantity - b.released_quantity;

  IF v_uninspected_count > 0 THEN
    RAISE EXCEPTION 'CLOSURE_INVENTORY_INSPECTION_INCOMPLETE';
  END IF;
END;
$$;


-- =========================================================
-- 7. REOPEN STORAGE POINT
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
  v_permission_exists BOOLEAN;
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

  SELECT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp
      ON rp.role_id = ur.role_id
    JOIN permissions p
      ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = 'storage_point_reopen'
  )
  INTO v_permission_exists;

  IF NOT v_permission_exists THEN
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

  PERFORM assert_storage_point_closure_inspected(
    p_storage_point_id,
    v_cycle_id
  );

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
-- 8. RELEASE INSPECTED CLOSURE BLOCK QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION release_storage_point_closure_block(
  p_closure_block_id UUID,
  p_quantity INTEGER,
  p_inspection_id UUID,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason_code TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_inspection RECORD;
  v_existing RECORD;
  v_released_from_inspection BIGINT;
  v_release_id UUID;
  v_permission_exists BOOLEAN;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'INVALID_RELEASE_QUANTITY';
  END IF;

  IF p_user_id IS NULL
     OR p_operation_key IS NULL
     OR p_inspection_id IS NULL THEN
    RAISE EXCEPTION 'RELEASE_ARGUMENTS_REQUIRED';
  END IF;

  IF p_reason_code IS NULL
     OR BTRIM(p_reason_code) = ''
     OR LENGTH(p_reason_code) > 2000 THEN
    RAISE EXCEPTION 'CLOSURE_BLOCK_RELEASE_REASON_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ACTIVE_USER_REQUIRED';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp
      ON rp.role_id = ur.role_id
    JOIN permissions p
      ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = 'storage_point_reopen'
  )
  INTO v_permission_exists;

  IF NOT v_permission_exists THEN
    RAISE EXCEPTION 'STORAGE_POINT_REOPEN_PERMISSION_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_operation_key::TEXT, 0)
  );

  SELECT *
  INTO v_existing
  FROM storage_point_closure_block_movements
  WHERE operation_key = p_operation_key;

  IF FOUND THEN
    IF v_existing.closure_block_id
          IS DISTINCT FROM p_closure_block_id
       OR v_existing.movement_type <> 'release'
       OR v_existing.quantity IS DISTINCT FROM p_quantity
       OR v_existing.inspection_id IS DISTINCT FROM p_inspection_id
       OR v_existing.created_by IS DISTINCT FROM p_user_id
       OR v_existing.reason_code IS DISTINCT FROM p_reason_code THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
    END IF;

    RETURN v_existing.id;
  END IF;

  SELECT
    b.id,
    b.storage_point_id,
    b.product_id,
    b.closure_cycle_id,
    b.initial_quantity,
    b.released_quantity
  INTO v_block
  FROM storage_point_closure_blocks b
  WHERE b.id = p_closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_BLOCK_NOT_FOUND';
  END IF;

  SELECT
    i.id,
    i.closure_block_id,
    i.closure_cycle_id,
    i.suitable_quantity
  INTO v_inspection
  FROM storage_point_closure_inspections i
  WHERE i.id = p_inspection_id
    AND i.closure_block_id = p_closure_block_id
    AND i.closure_cycle_id = v_block.closure_cycle_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_INSPECTION_NOT_FOUND';
  END IF;

  SELECT COALESCE(SUM(m.quantity), 0)
  INTO v_released_from_inspection
  FROM storage_point_closure_block_movements m
  WHERE m.inspection_id = p_inspection_id
    AND m.movement_type = 'release';

  IF v_released_from_inspection + p_quantity >
     v_inspection.suitable_quantity THEN
    RAISE EXCEPTION 'RELEASE_EXCEEDS_INSPECTED_SUITABLE_QUANTITY';
  END IF;

  IF v_block.released_quantity + p_quantity >
     v_block.initial_quantity THEN
    RAISE EXCEPTION 'RELEASE_EXCEEDS_REMAINING_CLOSURE_BLOCK';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles c
    WHERE c.id = v_block.closure_cycle_id
      AND c.reopened_at IS NULL
  ) THEN
    RAISE EXCEPTION 'STORAGE_POINT_MUST_BE_REOPENED_BEFORE_RELEASE';
  END IF;

  UPDATE storage_point_closure_blocks
  SET released_quantity = released_quantity + p_quantity
  WHERE id = p_closure_block_id;

  INSERT INTO storage_point_closure_block_movements (
    closure_block_id,
    movement_type,
    quantity,
    inspection_id,
    operation_key,
    reason_code,
    created_by
  )
  VALUES (
    p_closure_block_id,
    'release',
    p_quantity,
    p_inspection_id,
    p_operation_key,
    BTRIM(p_reason_code),
    p_user_id
  )
  RETURNING id INTO v_release_id;

  RETURN v_release_id;
END;
$$;


-- =========================================================
-- 9. RELEASE INSPECTED QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION release_inspected_closure_quantity(
  p_inspection_id UUID,
  p_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason_code TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_block_id UUID;
  v_movement_id UUID;
BEGIN
  SELECT closure_block_id
  INTO v_block_id
  FROM storage_point_closure_inspections
  WHERE id = p_inspection_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_INSPECTION_NOT_FOUND';
  END IF;

  v_movement_id := release_storage_point_closure_block(
    v_block_id,
    p_quantity,
    p_inspection_id,
    p_user_id,
    p_operation_key,
    p_reason_code
  );

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 10. CLOSURE INSPECTION STATUS
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_inspection_status AS
SELECT
  b.id AS closure_block_id,
  b.closure_cycle_id,
  b.storage_point_id,
  sp.name AS storage_point_name,
  b.inventory_id,
  b.product_id,
  p.sku,
  p.name AS product_name,

  b.initial_quantity,
  b.released_quantity,

  b.initial_quantity - b.released_quantity
    AS remaining_blocked_quantity,

  COALESCE(inspected.inspected_quantity, 0)
    AS inspected_quantity,

  COALESCE(inspected.suitable_quantity, 0)
    AS suitable_quantity,

  COALESCE(inspected.unsuitable_quantity, 0)
    AS unsuitable_quantity,

  GREATEST(
    b.initial_quantity - b.released_quantity
    - COALESCE(inspected.inspected_quantity, 0),
    0
  ) AS uninspected_quantity,

  c.reopened_at,

  CASE
    WHEN b.initial_quantity = b.released_quantity
      THEN 'released'

    WHEN b.initial_quantity - b.released_quantity
         - COALESCE(inspected.inspected_quantity, 0) > 0
      THEN 'inspection_incomplete'

    WHEN COALESCE(inspected.suitable_quantity, 0) = 0
      THEN 'no_suitable_stock'

    ELSE 'inspection_complete'
  END AS inspection_status

FROM storage_point_closure_blocks b

JOIN storage_points sp
  ON sp.id = b.storage_point_id

JOIN products p
  ON p.id = b.product_id

JOIN storage_point_closure_cycles c
  ON c.id = b.closure_cycle_id

LEFT JOIN LATERAL (
  SELECT
    SUM(i.inspected_quantity) AS inspected_quantity,
    SUM(i.suitable_quantity) AS suitable_quantity,
    SUM(i.unsuitable_quantity) AS unsuitable_quantity
  FROM storage_point_closure_inspections i
  WHERE i.closure_block_id = b.id
) inspected ON TRUE;


-- =========================================================
-- 11. INSPECTION INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_inspection_integrity AS
SELECT
  i.id AS inspection_id,
  i.closure_block_id,
  i.closure_cycle_id,
  i.inspected_by,
  i.inspected_at,
  i.inspected_quantity,
  i.suitable_quantity,
  i.unsuitable_quantity,

  COALESCE(released.quantity, 0)
    AS released_from_inspection,

  i.suitable_quantity - COALESCE(released.quantity, 0)
    AS remaining_suitable_quantity,

  CASE
    WHEN i.inspected_quantity < 0 THEN FALSE
    WHEN i.suitable_quantity < 0 THEN FALSE
    WHEN i.suitable_quantity > i.inspected_quantity THEN FALSE
    WHEN COALESCE(released.quantity, 0) > i.suitable_quantity THEN FALSE
    ELSE TRUE
  END AS is_valid

FROM storage_point_closure_inspections i

LEFT JOIN LATERAL (
  SELECT SUM(m.quantity) AS quantity
  FROM storage_point_closure_block_movements m
  WHERE m.inspection_id = i.id
    AND m.movement_type = 'release'
) released ON TRUE;


-- =========================================================
-- 12. CLOSURE INSPECTION MONITORING
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_inspection_issues AS
SELECT
  s.*,
  CASE
    WHEN s.uninspected_quantity > 0
      THEN 'inspection_incomplete'

    WHEN s.inspected_quantity >
         s.initial_quantity - s.released_quantity
      THEN 'inspection_overcommitted'

    WHEN s.suitable_quantity >
         s.inspected_quantity
      THEN 'suitable_quantity_invalid'

    ELSE 'no_issue'
  END AS issue_type

FROM v_storage_point_closure_inspection_status s

WHERE s.uninspected_quantity > 0
   OR s.inspected_quantity >
      s.initial_quantity - s.released_quantity;