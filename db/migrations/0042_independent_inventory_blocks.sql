-- =========================================================
-- 1. CLARIFICATION OF THE REASONS FOR INDEPENDET BLOCKING
-- =========================================================

ALTER TABLE inventory_blocks
  ADD COLUMN IF NOT EXISTS reason TEXT;

ALTER TABLE inventory_blocks
  ADD COLUMN IF NOT EXISTS comment TEXT;

ALTER TABLE inventory_blocks
  ADD COLUMN IF NOT EXISTS created_by UUID
    REFERENCES users(id);

ALTER TABLE inventory_blocks
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ
    NOT NULL DEFAULT NOW();

ALTER TABLE inventory_blocks
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ
    NOT NULL DEFAULT NOW();

ALTER TABLE inventory_blocks
  ADD CONSTRAINT inventory_blocks_reason_check
  CHECK (
    reason IS NULL
    OR reason IN (
      'damage',
      'suspected_damage',
      'loss',
      'other'
    )
  );

ALTER TABLE inventory_blocks
  ADD CONSTRAINT inventory_blocks_comment_check
  CHECK (
    comment IS NULL
    OR LENGTH(comment) <= 2000
  );

ALTER TABLE inventory_blocks
  ADD CONSTRAINT inventory_blocks_other_reason_comment_check
  CHECK (
    reason IS DISTINCT FROM 'other'
    OR (
      comment IS NOT NULL
      AND LENGTH(TRIM(comment)) > 0
    )
  );


-- =========================================================
-- 2. INDEPENDENT BLOCKING MOVEMENT LOG
-- =========================================================

CREATE TABLE inventory_block_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  inventory_block_id UUID NOT NULL
    REFERENCES inventory_blocks(id),

  movement_type TEXT NOT NULL,

  quantity INTEGER NOT NULL,

  reason TEXT,

  comment TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT inventory_block_movement_type_check
    CHECK (
      movement_type IN ('block', 'unblock')
    ),

  CONSTRAINT inventory_block_movement_quantity_check
    CHECK (quantity > 0),

  CONSTRAINT inventory_block_movement_reason_check
    CHECK (
      reason IS NULL
      OR reason IN (
        'damage',
        'suspected_damage',
        'loss',
        'other'
      )
    ),

  CONSTRAINT inventory_block_movement_comment_check
    CHECK (
      comment IS NULL
      OR LENGTH(comment) <= 2000
    ),

  CONSTRAINT inventory_block_movement_other_reason_check
    CHECK (
      reason IS DISTINCT FROM 'other'
      OR (
        comment IS NOT NULL
        AND LENGTH(TRIM(comment)) > 0
      )
    )
);

CREATE INDEX inventory_block_movements_history_idx
  ON inventory_block_movements(
    inventory_block_id,
    created_at DESC
  );


-- =========================================================
-- 3. IMMUTABILITY OF THE JOURNAL
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_inventory_block_movement_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Журнал незалежних блокувань є незмінним';
END;
$$;

CREATE TRIGGER inventory_block_movements_immutable
BEFORE UPDATE OR DELETE
ON inventory_block_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_inventory_block_movement_mutation();


-- =========================================================
-- 4. BLOCKING RESIDUE CONTROL
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_block_quantities()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
  v_active_blocks BIGINT;
BEGIN
  SELECT
    i.id,
    i.quantity,
    i.blocked_quantity
  INTO v_inventory
  FROM inventory i
  WHERE i.id = NEW.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Залишок товару не знайдено';
  END IF;

  IF NEW.initial_quantity <= 0 THEN
    RAISE EXCEPTION
      'Початкова кількість блокування має бути більшою за нуль';
  END IF;

  IF NEW.unblocked_quantity < 0
     OR NEW.unblocked_quantity > NEW.initial_quantity THEN
    RAISE EXCEPTION
      'Некоректна кількість розблокованого товару';
  END IF;

  SELECT COALESCE(
    SUM(b.initial_quantity - b.unblocked_quantity),
    0
  )
  INTO v_active_blocks
  FROM inventory_blocks b
  WHERE b.inventory_id = NEW.inventory_id
    AND b.id <> NEW.id;

  v_active_blocks := v_active_blocks
    + NEW.initial_quantity
    - NEW.unblocked_quantity;

  IF v_active_blocks > v_inventory.quantity THEN
    RAISE EXCEPTION
      'Сумарна кількість незалежно заблокованого товару перевищує фізичний залишок';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_blocks_quantity_guard
BEFORE INSERT OR UPDATE
ON inventory_blocks
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_block_quantities();


-- =========================================================
-- 5. MOVEMENT LOG CONTROL
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_block_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_total_blocked BIGINT;
BEGIN
  SELECT
    b.id,
    b.initial_quantity,
    b.unblocked_quantity,
    b.inventory_id
  INTO v_block
  FROM inventory_blocks b
  WHERE b.id = NEW.inventory_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування не знайдено';
  END IF;

  IF NEW.movement_type = 'unblock' THEN
    IF NEW.quantity >
       v_block.initial_quantity - v_block.unblocked_quantity THEN
      RAISE EXCEPTION
        'Кількість розблокування перевищує активне блокування';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_block_movement_guard
BEFORE INSERT
ON inventory_block_movements
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_block_movement();


-- =========================================================
-- 6. CHECKING OF INDEPENDENT INTERLOCKS
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_independent_block_status AS
SELECT
  b.id AS inventory_block_id,
  b.inventory_id,
  b.initial_quantity,
  b.unblocked_quantity,

  b.initial_quantity - b.unblocked_quantity
    AS remaining_blocked_quantity,

  b.reason,
  b.comment,
  b.created_by,
  b.created_at

FROM inventory_blocks b

WHERE b.initial_quantity > b.unblocked_quantity;


-- =========================================================
-- 7. VERIFICATION OF THE TOTAL BALANCE BLOCK
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_total_block_status AS
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,
  i.quantity,
  i.reserved_quantity,

  i.blocked_quantity AS recorded_blocked_quantity,

  COALESCE(independent.independent_blocked, 0)
    AS independent_blocked_quantity,

  COALESCE(closure.closure_blocked, 0)
    AS closure_blocked_quantity,

  (
    i.quantity
    - i.reserved_quantity
    - i.blocked_quantity
    - COALESCE(closure.closure_blocked, 0)
  ) AS available_after_closure_blocks

FROM inventory i

LEFT JOIN LATERAL (
  SELECT
    SUM(
      b.initial_quantity - b.unblocked_quantity
    ) AS independent_blocked
  FROM inventory_blocks b
  WHERE b.inventory_id = i.id
) independent ON TRUE

LEFT JOIN LATERAL (
  SELECT
    SUM(
      b.initial_quantity - b.released_quantity
    ) AS closure_blocked
  FROM storage_point_closure_blocks b
  WHERE b.storage_point_id = i.storage_point_id
    AND b.product_id = i.product_id
) closure ON TRUE;