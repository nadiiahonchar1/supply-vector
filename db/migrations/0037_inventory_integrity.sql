-- =========================================================
-- 1. INVENTORY ROW VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.quantity < 0
     OR NEW.reserved_quantity < 0
     OR NEW.blocked_quantity < 0 THEN
    RAISE EXCEPTION 'INVALID_INVENTORY_BALANCE';
  END IF;

  IF NEW.reserved_quantity + NEW.blocked_quantity
     > NEW.quantity THEN
    RAISE EXCEPTION 'INVENTORY_ALLOCATED_EXCEEDS_PHYSICAL';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_balance_integrity_guard
ON inventory;

CREATE TRIGGER inventory_balance_integrity_guard
BEFORE INSERT OR UPDATE
ON inventory
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_balance();


-- =========================================================
-- 2. RESERVATION ROW VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_reservation_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.reserved_quantity <= 0 THEN
    RAISE EXCEPTION 'INVALID_RESERVATION_QUANTITY';
  END IF;

  IF NEW.consumed_quantity < 0
     OR NEW.released_quantity < 0 THEN
    RAISE EXCEPTION 'INVALID_RESERVATION_MOVEMENT_QUANTITY';
  END IF;

  IF NEW.consumed_quantity + NEW.released_quantity
     > NEW.reserved_quantity THEN
    RAISE EXCEPTION 'RESERVATION_ACCOUNTING_EXCEEDS_ORIGINAL';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_reservation_balance_guard
ON inventory_reservations;

CREATE TRIGGER inventory_reservation_balance_guard
BEFORE INSERT OR UPDATE
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_reservation_balance();


-- =========================================================
-- 3. INVENTORY BLOCK ROW VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_block_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.initial_quantity <= 0 THEN
    RAISE EXCEPTION 'INVALID_INITIAL_BLOCK_QUANTITY';
  END IF;

  IF NEW.unblocked_quantity < 0
     OR NEW.unblocked_quantity > NEW.initial_quantity THEN
    RAISE EXCEPTION 'INVALID_UNBLOCKED_QUANTITY';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_block_balance_guard
ON inventory_blocks;

CREATE TRIGGER inventory_block_balance_guard
BEFORE INSERT OR UPDATE
ON inventory_blocks
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_block_balance();


-- =========================================================
-- 4. RESERVATION BALANCE INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_reservation_integrity AS
WITH reservation_totals AS (
  SELECT
    inventory_id,

    SUM(
      reserved_quantity
      - consumed_quantity
      - released_quantity
    )::BIGINT AS calculated_reserved_quantity

  FROM inventory_reservations
  GROUP BY inventory_id
)
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.reserved_quantity::BIGINT
    AS recorded_reserved_quantity,

  COALESCE(
    rt.calculated_reserved_quantity,
    0
  ) AS calculated_reserved_quantity,

  (
    i.reserved_quantity::BIGINT
    - COALESCE(rt.calculated_reserved_quantity, 0)
  ) AS difference,

  (
    i.reserved_quantity::BIGINT
    = COALESCE(rt.calculated_reserved_quantity, 0)
  ) AS is_valid

FROM inventory i

LEFT JOIN reservation_totals rt
  ON rt.inventory_id = i.id;


-- =========================================================
-- 5. INVENTORY BLOCK BALANCE INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_block_integrity AS
WITH block_totals AS (
  SELECT
    inventory_id,

    SUM(
      initial_quantity - unblocked_quantity
    )::BIGINT AS calculated_blocked_quantity

  FROM inventory_blocks
  GROUP BY inventory_id
)
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.blocked_quantity::BIGINT
    AS recorded_blocked_quantity,

  COALESCE(
    bt.calculated_blocked_quantity,
    0
  ) AS calculated_blocked_quantity,

  (
    i.blocked_quantity::BIGINT
    - COALESCE(bt.calculated_blocked_quantity, 0)
  ) AS difference,

  (
    i.blocked_quantity::BIGINT
    = COALESCE(bt.calculated_blocked_quantity, 0)
  ) AS is_valid

FROM inventory i

LEFT JOIN block_totals bt
  ON bt.inventory_id = i.id;


-- =========================================================
-- 6. RESERVATION MOVEMENT JOURNAL INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_reservation_movement_integrity AS
WITH movement_totals AS (
  SELECT
    reservation_id,

    SUM(quantity) FILTER (
      WHERE movement_type = 'reserve'
    )::BIGINT AS reserved_quantity,

    SUM(quantity) FILTER (
      WHERE movement_type = 'consume'
    )::BIGINT AS consumed_quantity,

    SUM(quantity) FILTER (
      WHERE movement_type = 'release'
    )::BIGINT AS released_quantity

  FROM inventory_reservation_movements
  GROUP BY reservation_id
)
SELECT
  r.id AS reservation_id,
  r.inventory_id,
  r.transfer_request_source_id,

  r.reserved_quantity::BIGINT
    AS recorded_reserved_quantity,

  r.consumed_quantity::BIGINT
    AS recorded_consumed_quantity,

  r.released_quantity::BIGINT
    AS recorded_released_quantity,

  COALESCE(mt.reserved_quantity, 0)
    AS journal_reserved_quantity,

  COALESCE(mt.consumed_quantity, 0)
    AS journal_consumed_quantity,

  COALESCE(mt.released_quantity, 0)
    AS journal_released_quantity,

  (
    r.reserved_quantity::BIGINT
      - COALESCE(mt.reserved_quantity, 0)
  ) AS reserved_difference,

  (
    r.consumed_quantity::BIGINT
      - COALESCE(mt.consumed_quantity, 0)
  ) AS consumed_difference,

  (
    r.released_quantity::BIGINT
      - COALESCE(mt.released_quantity, 0)
  ) AS released_difference

FROM inventory_reservations r

LEFT JOIN movement_totals mt
  ON mt.reservation_id = r.id;


-- =========================================================
-- 7. INVENTORY BLOCK MOVEMENT JOURNAL INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_block_movement_integrity AS
WITH movement_totals AS (
  SELECT
    block_id,

    SUM(quantity) FILTER (
      WHERE movement_type = 'block'
    )::BIGINT AS blocked_quantity,

    SUM(quantity) FILTER (
      WHERE movement_type = 'unblock'
    )::BIGINT AS unblocked_quantity

  FROM inventory_block_movements
  GROUP BY block_id
)
SELECT
  b.id AS block_id,
  b.inventory_id,

  b.initial_quantity::BIGINT
    AS recorded_initial_quantity,

  b.unblocked_quantity::BIGINT
    AS recorded_unblocked_quantity,

  COALESCE(mt.blocked_quantity, 0)
    AS journal_blocked_quantity,

  COALESCE(mt.unblocked_quantity, 0)
    AS journal_unblocked_quantity,

  (
    b.initial_quantity::BIGINT
    - COALESCE(mt.blocked_quantity, 0)
  ) AS initial_quantity_difference,

  (
    b.unblocked_quantity::BIGINT
    - COALESCE(mt.unblocked_quantity, 0)
  ) AS unblocked_quantity_difference

FROM inventory_blocks b

LEFT JOIN movement_totals mt
  ON mt.block_id = b.id;


-- =========================================================
-- 8. UNIFIED INVENTORY INTEGRITY ISSUES
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_integrity_issues AS

SELECT
  'reservation_balance_mismatch'::TEXT AS issue_type,
  inventory_id,
  storage_point_id,
  product_id,
  difference
FROM v_inventory_reservation_integrity
WHERE difference <> 0

UNION ALL

SELECT
  'block_balance_mismatch'::TEXT AS issue_type,
  inventory_id,
  storage_point_id,
  product_id,
  difference
FROM v_inventory_block_integrity
WHERE difference <> 0

UNION ALL

SELECT
  'negative_available_quantity'::TEXT AS issue_type,
  id AS inventory_id,
  storage_point_id,
  product_id,
  (
    quantity::BIGINT
    - reserved_quantity::BIGINT
    - blocked_quantity::BIGINT
  ) AS difference
FROM inventory
WHERE
  quantity < 0
  OR reserved_quantity < 0
  OR blocked_quantity < 0
  OR reserved_quantity + blocked_quantity > quantity;


-- =========================================================
-- 9. RESERVATION JOURNAL ISSUES
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_reservation_journal_issues AS
SELECT
  reservation_id,
  inventory_id,
  transfer_request_source_id,

  reserved_difference,
  consumed_difference,
  released_difference

FROM v_inventory_reservation_movement_integrity

WHERE reserved_difference <> 0
   OR consumed_difference <> 0
   OR released_difference <> 0;


-- =========================================================
-- 10. BLOCK JOURNAL ISSUES
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_block_journal_issues AS
SELECT
  block_id,
  inventory_id,

  initial_quantity_difference,
  unblocked_quantity_difference

FROM v_inventory_block_movement_integrity

WHERE initial_quantity_difference <> 0
   OR unblocked_quantity_difference <> 0;


-- =========================================================
-- 11. AVAILABLE INVENTORY INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_availability_integrity AS
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.quantity,
  i.reserved_quantity,
  i.blocked_quantity,

  (
    i.quantity::BIGINT
    - i.reserved_quantity::BIGINT
    - i.blocked_quantity::BIGINT
  ) AS available_quantity,

  CASE
    WHEN i.quantity < 0
      OR i.reserved_quantity < 0
      OR i.blocked_quantity < 0
    THEN FALSE

    WHEN i.reserved_quantity + i.blocked_quantity
         > i.quantity
    THEN FALSE

    ELSE TRUE
  END AS is_valid

FROM inventory i;


-- =========================================================
-- 12. INVENTORY MOVEMENT BALANCE INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_movement_integrity AS
SELECT
  im.id AS movement_id,
  im.storage_point_id,
  im.product_id,

  im.movement_type,
  im.quantity,

  im.quantity_before,
  im.quantity_after,

  CASE
    WHEN im.movement_type IN (
      'receipt',
      'shipment_receive',
      'shipment_return',
      'salvage_return'
    )
    THEN im.quantity_before + im.quantity

    WHEN im.movement_type IN (
      'shipment_load',
      'writeoff'
    )
    THEN im.quantity_before - im.quantity

    WHEN im.movement_type = 'adjustment'
    THEN im.quantity_after

    ELSE NULL
  END AS expected_quantity_after,

  CASE
    WHEN im.movement_type = 'adjustment'
    THEN
      im.quantity = ABS(
        im.quantity_after - im.quantity_before
      )
      AND im.quantity_after <> im.quantity_before

    WHEN im.movement_type IN (
      'receipt',
      'shipment_receive',
      'shipment_return',
      'salvage_return'
    )
    THEN
      im.quantity_after =
      im.quantity_before + im.quantity

    WHEN im.movement_type IN (
      'shipment_load',
      'writeoff'
    )
    THEN
      im.quantity_after =
      im.quantity_before - im.quantity

    ELSE FALSE
  END AS is_valid

FROM inventory_movements im;


-- =========================================================
-- 13. COMPLETE INVENTORY INTEGRITY SUMMARY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_integrity_summary AS
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.quantity,
  i.reserved_quantity,
  i.blocked_quantity,

  (
    i.quantity::BIGINT
    - i.reserved_quantity::BIGINT
    - i.blocked_quantity::BIGINT
  ) AS available_quantity,

  ri.is_valid AS reservation_balance_valid,
  bi.is_valid AS block_balance_valid,

  (
    i.quantity >= 0
    AND i.reserved_quantity >= 0
    AND i.blocked_quantity >= 0
    AND i.reserved_quantity + i.blocked_quantity
        <= i.quantity
  ) AS physical_balance_valid,

  NOT EXISTS (
    SELECT 1
    FROM v_inventory_reservation_journal_issues rji
    WHERE rji.inventory_id = i.id
  ) AS reservation_journal_valid,

  NOT EXISTS (
    SELECT 1
    FROM v_inventory_block_journal_issues bji
    WHERE bji.inventory_id = i.id
  ) AS block_journal_valid

FROM inventory i

JOIN v_inventory_reservation_integrity ri
  ON ri.inventory_id = i.id

JOIN v_inventory_block_integrity bi
  ON bi.inventory_id = i.id;