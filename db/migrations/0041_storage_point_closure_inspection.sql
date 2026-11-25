-- =========================================================
-- 1. VERIFICATION OF DATA QUANTITY AND INTEGRITY
-- =========================================================

ALTER TABLE storage_point_closure_inspections
  ADD COLUMN IF NOT EXISTS closure_cycle_id UUID
    REFERENCES storage_point_closure_cycles(id);

UPDATE storage_point_closure_inspections i
SET closure_cycle_id = b.closure_cycle_id
FROM storage_point_closure_blocks b
WHERE b.id = i.block_id
  AND i.closure_cycle_id IS NULL;

ALTER TABLE storage_point_closure_inspections
  ALTER COLUMN closure_cycle_id SET NOT NULL;

ALTER TABLE storage_point_closure_inspections
  ADD COLUMN IF NOT EXISTS unsuitable_quantity INTEGER
    GENERATED ALWAYS AS (
      inspected_quantity - suitable_quantity
    ) STORED;

ALTER TABLE storage_point_closure_inspections
  ADD CONSTRAINT closure_inspection_quantity_check
  CHECK (
    inspected_quantity >= 0
    AND suitable_quantity >= 0
    AND suitable_quantity <= inspected_quantity
  );

ALTER TABLE storage_point_closure_inspections
  ADD CONSTRAINT closure_inspection_comment_check
  CHECK (
    comment IS NULL OR LENGTH(comment) <= 2000
  );


-- =========================================================
-- 2. INDEXES FOR INVENTORY HISTORY
-- =========================================================

CREATE INDEX storage_point_closure_inspections_block_idx
  ON storage_point_closure_inspections(block_id, inspected_at DESC);

CREATE INDEX storage_point_closure_inspections_cycle_idx
  ON storage_point_closure_inspections(
    closure_cycle_id,
    inspected_at DESC
  );


-- =========================================================
-- 3. VERIFICATION OF INTERLOCK AND CYCLE COMPLIANCE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_closure_inspection()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_cycle RECORD;
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
  WHERE b.id = NEW.block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування залишку не знайдено';
  END IF;

  SELECT
    c.id,
    c.storage_point_id,
    c.reopened_at
  INTO v_cycle
  FROM storage_point_closure_cycles c
  WHERE c.id = NEW.closure_cycle_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Цикл закриття не знайдено';
  END IF;

  IF v_block.closure_cycle_id <> NEW.closure_cycle_id
     OR v_block.storage_point_id <> v_cycle.storage_point_id THEN
    RAISE EXCEPTION
      'Інвентаризація не відповідає циклу закриття';
  END IF;

  IF NEW.inspected_quantity >
     v_block.initial_quantity - v_block.released_quantity THEN
    RAISE EXCEPTION
      'Перевірена кількість перевищує залишок блокування';
  END IF;

  IF NEW.suitable_quantity > NEW.inspected_quantity THEN
    RAISE EXCEPTION
      'Придатна кількість перевищує перевірену';
  END IF;

  IF v_cycle.reopened_at IS NULL THEN
    RAISE EXCEPTION
      'Інвентаризація для розблокування доступна після повторного відкриття точки';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_inspection_guard
BEFORE INSERT
ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION validate_closure_inspection();


-- =========================================================
-- 4. INVENTORIES AND THEIR RESULTS CANNOT BE CHANGED
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closure_inspection_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Записи інвентаризації незмінні. Для виправлення потрібен новий запис';
END;
$$;

CREATE TRIGGER storage_point_closure_inspection_immutable
BEFORE UPDATE OR DELETE
ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION prevent_closure_inspection_mutation();


-- =========================================================
-- 5. UNBLOCKING ONLY AFTER INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION release_inspected_closure_quantity(
  p_inspection_id UUID,
  p_quantity INTEGER,
  p_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_inspection RECORD;
  v_block RECORD;
  v_released_from_inspection INTEGER;
  v_release_id UUID;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість для розблокування має бути більшою за нуль';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION
      'Користувач неактивний або не існує';
  END IF;

  SELECT
    i.id,
    i.block_id,
    i.closure_cycle_id,
    i.suitable_quantity,
    i.inspected_by
  INTO v_inspection
  FROM storage_point_closure_inspections i
  WHERE i.id = p_inspection_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис інвентаризації не знайдено';
  END IF;

  IF v_inspection.inspected_by <> p_user_id THEN
   
    NULL;
  END IF;

  SELECT
    b.id,
    b.storage_point_id,
    b.product_id,
    b.initial_quantity,
    b.released_quantity,
    b.closure_cycle_id
  INTO v_block
  FROM storage_point_closure_blocks b
  WHERE b.id = v_inspection.block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування не знайдено';
  END IF;

  SELECT COALESCE(SUM(m.quantity), 0)
  INTO v_released_from_inspection
  FROM storage_point_closure_block_movements m
  WHERE m.inspection_id = p_inspection_id
    AND m.movement_type = 'release';

  IF v_released_from_inspection + p_quantity >
     v_inspection.suitable_quantity THEN
    RAISE EXCEPTION
      'Кількість перевищує придатний залишок за цією інвентаризацією';
  END IF;

  IF v_block.released_quantity + p_quantity >
     v_block.initial_quantity THEN
    RAISE EXCEPTION
      'Кількість перевищує нерозблокований залишок';
  END IF;

  PERFORM release_storage_point_closure_block(
    v_block.id,
    p_quantity,
    p_user_id,
    p_inspection_id
  );

  SELECT id
  INTO v_release_id
  FROM storage_point_closure_block_movements
  WHERE block_id = v_block.id
    AND inspection_id = p_inspection_id
    AND movement_type = 'release'
  ORDER BY created_at DESC
  LIMIT 1;

  RETURN v_release_id;
END;
$$;


-- =========================================================
-- 6. VERIFICATION OF BALANCES AFTER INVENTORY
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_inspection_status AS
SELECT
  b.id AS closure_block_id,
  b.closure_cycle_id,
  b.storage_point_id,
  sp.name AS storage_point_name,
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

  c.reopened_at,

  CASE
    WHEN b.initial_quantity = b.released_quantity
      THEN 'released'
    WHEN COALESCE(inspected.inspected_quantity, 0) = 0
      THEN 'not_inspected'
    WHEN COALESCE(inspected.suitable_quantity, 0) = 0
      THEN 'no_suitable_stock'
    ELSE 'inspection_in_progress'
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
  WHERE i.block_id = b.id
) inspected ON TRUE;