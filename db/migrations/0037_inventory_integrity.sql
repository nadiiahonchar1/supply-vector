-- =========================================================
-- 1. VERIFICATION OF PHYSICAL STOCK AND AVAILABLE QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.quantity < 0
     OR NEW.reserved_quantity < 0
     OR NEW.blocked_quantity < 0 THEN
    RAISE EXCEPTION
      'Кількість товару, резерв і блокування не можуть бути від’ємними';
  END IF;

  IF NEW.reserved_quantity + NEW.blocked_quantity
     > NEW.quantity THEN
    RAISE EXCEPTION
      'Сума резервів і блокувань перевищує фізичний залишок';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_balance_integrity_guard
BEFORE INSERT OR UPDATE
ON inventory
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_balance();


-- =========================================================
-- 2. RESERVE BALANCE MONITORING
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_reservation_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.reserved_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість резерву повинна бути більшою за нуль';
  END IF;

  IF NEW.consumed_quantity < 0
     OR NEW.released_quantity < 0 THEN
    RAISE EXCEPTION
      'Спожита та звільнена кількість не можуть бути від’ємними';
  END IF;

  IF NEW.consumed_quantity + NEW.released_quantity
     > NEW.reserved_quantity THEN
    RAISE EXCEPTION
      'Спожита та звільнена кількість перевищує початковий резерв';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_reservation_balance_guard
BEFORE INSERT OR UPDATE
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_reservation_balance();


-- =========================================================
-- 3. VERIFICATION OF RESERVE COMPLIANCE
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_reservation_integrity AS
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.reserved_quantity AS inventory_reserved_quantity,

  COALESCE(
    SUM(
      r.reserved_quantity
      - r.consumed_quantity
      - r.released_quantity
    ),
    0
  ) AS calculated_reserved_quantity,

  i.reserved_quantity
  -
  COALESCE(
    SUM(
      r.reserved_quantity
      - r.consumed_quantity
      - r.released_quantity
    ),
    0
  ) AS difference

FROM inventory i

LEFT JOIN inventory_reservations r
  ON r.inventory_id = i.id

GROUP BY
  i.id,
  i.storage_point_id,
  i.product_id,
  i.reserved_quantity;


-- =========================================================
-- 4. VERIFICATION OF INTERLOCK COMPLIANCE
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_block_integrity AS
SELECT
  i.id AS inventory_id,
  i.storage_point_id,
  i.product_id,

  i.blocked_quantity AS inventory_blocked_quantity,

  COALESCE(
    SUM(
      b.initial_quantity - b.unblocked_quantity
    ),
    0
  ) AS calculated_blocked_quantity,

  i.blocked_quantity
  -
  COALESCE(
    SUM(
      b.initial_quantity - b.unblocked_quantity
    ),
    0
  ) AS difference

FROM inventory i

LEFT JOIN inventory_blocks b
  ON b.inventory_id = i.id

GROUP BY
  i.id,
  i.storage_point_id,
  i.product_id,
  i.blocked_quantity;


-- =========================================================
-- 5. A UNIFIED VIEW OF WAREHOUSE ACCOUNTING PROBLEMS
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_integrity_issues AS

SELECT
  'reservation_mismatch'::TEXT AS issue_type,
  inventory_id,
  storage_point_id,
  product_id,
  difference
FROM v_inventory_reservation_integrity
WHERE difference <> 0

UNION ALL

SELECT
  'block_mismatch'::TEXT AS issue_type,
  inventory_id,
  storage_point_id,
  product_id,
  difference
FROM v_inventory_block_integrity
WHERE difference <> 0;


-- =========================================================
-- 6. CHECKING AVAILABLE BALANCE
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
    i.quantity
    - i.reserved_quantity
    - i.blocked_quantity
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