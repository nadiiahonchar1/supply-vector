-- =========================================================
-- 1. CLOSURE BLOCK METADATA
-- =========================================================

ALTER TABLE storage_point_closure_blocks
  ADD COLUMN IF NOT EXISTS created_by UUID
    REFERENCES users(id) ON DELETE RESTRICT;

ALTER TABLE storage_point_closure_blocks
  ALTER COLUMN closure_id DROP NOT NULL;


-- =========================================================
-- 2. CLOSURE BLOCK ACCOUNTING VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_storage_point_closure_block()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
  v_cycle RECORD;
BEGIN
  IF NEW.initial_quantity IS NULL
     OR NEW.initial_quantity < 0
     OR NEW.released_quantity IS NULL
     OR NEW.released_quantity < 0
     OR NEW.released_quantity > NEW.initial_quantity THEN
    RAISE EXCEPTION 'INVALID_CLOSURE_BLOCK_QUANTITY';
  END IF;

  SELECT
    id,
    storage_point_id,
    product_id
  INTO v_inventory
  FROM inventory
  WHERE id = NEW.inventory_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
  END IF;

  IF v_inventory.storage_point_id <> NEW.storage_point_id
     OR v_inventory.product_id <> NEW.product_id THEN
    RAISE EXCEPTION 'CLOSURE_BLOCK_INVENTORY_REFERENCE_MISMATCH';
  END IF;

  SELECT
    id,
    storage_point_id,
    reopened_at
  INTO v_cycle
  FROM storage_point_closure_cycles
  WHERE id = NEW.closure_cycle_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_NOT_FOUND';
  END IF;

  IF v_cycle.storage_point_id <> NEW.storage_point_id THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_STORAGE_POINT_MISMATCH';
  END IF;

  IF v_cycle.reopened_at IS NOT NULL THEN
    RAISE EXCEPTION 'CANNOT_ADD_BLOCK_TO_REOPENED_CYCLE';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS storage_point_closure_block_accounting_guard
ON storage_point_closure_blocks;

CREATE TRIGGER storage_point_closure_block_accounting_guard
BEFORE INSERT OR UPDATE
ON storage_point_closure_blocks
FOR EACH ROW
EXECUTE FUNCTION validate_storage_point_closure_block();


-- =========================================================
-- 3. REMAINING CLOSURE BLOCK QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION get_storage_point_closure_blocked_quantity(
  p_storage_point_id UUID,
  p_product_id UUID
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    SUM(
      cb.initial_quantity::BIGINT
      - cb.released_quantity::BIGINT
    ),
    0
  )
  FROM storage_point_closure_blocks cb
  WHERE cb.storage_point_id = p_storage_point_id
    AND cb.product_id = p_product_id
    AND cb.initial_quantity > cb.released_quantity;
$$;


-- =========================================================
-- 4. EFFECTIVE INVENTORY AVAILABILITY
-- =========================================================

CREATE OR REPLACE FUNCTION get_effective_inventory_available(
  p_storage_point_id UUID,
  p_product_id UUID
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
  SELECT
    CASE
      WHEN sp.status = 'closed' THEN 0

      ELSE GREATEST(
        i.quantity::BIGINT
        - i.reserved_quantity::BIGINT
        - i.blocked_quantity::BIGINT
        - get_storage_point_closure_blocked_quantity(
            i.storage_point_id,
            i.product_id
          ),
        0
      )
    END
  FROM inventory i
  JOIN storage_points sp
    ON sp.id = i.storage_point_id
  WHERE i.storage_point_id = p_storage_point_id
    AND i.product_id = p_product_id;
$$;


-- =========================================================
-- 5. EFFECTIVE INVENTORY AVAILABILITY VIEW
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_effective_availability AS
SELECT
  i.id AS inventory_id,

  i.storage_point_id,
  sp.name AS storage_point_name,
  sp.status AS storage_point_status,

  i.product_id,
  p.sku,
  p.name AS product_name,

  i.quantity AS physical_quantity,
  i.reserved_quantity,
  i.blocked_quantity,

  get_storage_point_closure_blocked_quantity(
    i.storage_point_id,
    i.product_id
  ) AS closure_blocked_quantity,

  (
    i.quantity::BIGINT
    - i.reserved_quantity::BIGINT
    - i.blocked_quantity::BIGINT
    - get_storage_point_closure_blocked_quantity(
        i.storage_point_id,
        i.product_id
      )
  ) AS calculated_available_quantity,

  CASE
    WHEN sp.status = 'closed' THEN 0::BIGINT

    ELSE GREATEST(
      i.quantity::BIGINT
      - i.reserved_quantity::BIGINT
      - i.blocked_quantity::BIGINT
      - get_storage_point_closure_blocked_quantity(
          i.storage_point_id,
          i.product_id
        ),
      0
    )
  END AS effective_available_quantity

FROM inventory i

JOIN storage_points sp
  ON sp.id = i.storage_point_id

JOIN products p
  ON p.id = i.product_id;


-- =========================================================
-- 6. CLOSURE BLOCK BALANCE INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_block_integrity AS
SELECT
  cb.id AS closure_block_id,

  cb.closure_id,
  cb.closure_cycle_id,

  cb.storage_point_id,
  cb.inventory_id,
  cb.product_id,

  cb.initial_quantity,
  cb.released_quantity,

  (
    cb.initial_quantity::BIGINT
    - cb.released_quantity::BIGINT
  ) AS remaining_quantity,

  cc.reopened_at,

  CASE
    WHEN cb.initial_quantity < 0 THEN FALSE
    WHEN cb.released_quantity < 0 THEN FALSE
    WHEN cb.released_quantity > cb.initial_quantity THEN FALSE
    WHEN cc.id IS NULL THEN FALSE
    WHEN cc.storage_point_id <> cb.storage_point_id THEN FALSE
    WHEN i.id IS NULL THEN FALSE
    WHEN i.storage_point_id <> cb.storage_point_id THEN FALSE
    WHEN i.product_id <> cb.product_id THEN FALSE
    ELSE TRUE
  END AS is_valid

FROM storage_point_closure_blocks cb

LEFT JOIN storage_point_closure_cycles cc
  ON cc.id = cb.closure_cycle_id

LEFT JOIN inventory i
  ON i.id = cb.inventory_id;


-- =========================================================
-- 7. EFFECTIVE AVAILABILITY INTEGRITY ISSUES
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_effective_availability_issues AS
SELECT
  inventory_id,

  storage_point_id,
  storage_point_name,
  storage_point_status,

  product_id,
  sku,
  product_name,

  physical_quantity,
  reserved_quantity,
  blocked_quantity,
  closure_blocked_quantity,

  calculated_available_quantity,
  effective_available_quantity,

  CASE
    WHEN calculated_available_quantity < 0
      THEN 'availability_overcommitted'

    WHEN storage_point_status = 'closed'
      THEN 'storage_point_closed'

    ELSE 'no_issue'
  END AS issue_type

FROM v_inventory_effective_availability

WHERE calculated_available_quantity < 0
   OR storage_point_status = 'closed';


-- =========================================================
-- 8. CLOSURE BLOCK MONITORING
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
    cb.initial_quantity::BIGINT
    - cb.released_quantity::BIGINT
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