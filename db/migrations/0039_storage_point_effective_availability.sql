-- =========================================================
-- 1. FUNCTION FOR CALCULATING REMAINING BLOCKING AFTER CLOSURE
-- =========================================================

CREATE OR REPLACE FUNCTION get_storage_point_closure_blocked_quantity(
  p_storage_point_id UUID,
  p_product_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    SUM(
      b.initial_quantity - b.released_quantity
    ),
    0
  )
  FROM storage_point_closure_blocks b
  WHERE b.storage_point_id = p_storage_point_id
    AND b.product_id = p_product_id
    AND b.initial_quantity > b.released_quantity;
$$;


-- =========================================================
-- 2. FUNCTION FOR CALCULATING THE ACTUALLY AVAILABLE BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION get_effective_inventory_available(
  p_storage_point_id UUID,
  p_product_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(
    i.quantity
    - i.reserved_quantity
    - i.blocked_quantity
    - get_storage_point_closure_blocked_quantity(
        i.storage_point_id,
        i.product_id
      ),
    0
  )
  FROM inventory i
  WHERE i.storage_point_id = p_storage_point_id
    AND i.product_id = p_product_id;
$$;


-- =========================================================
-- 3. REPRESENTATION OF ACTUAL PRODUCT AVAILABILITY
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
    i.quantity
    - i.reserved_quantity
    - i.blocked_quantity
    - get_storage_point_closure_blocked_quantity(
        i.storage_point_id,
        i.product_id
      )
  ) AS calculated_available_quantity,

  CASE
    WHEN sp.status = 'closed' THEN 0

    ELSE GREATEST(
      i.quantity
      - i.reserved_quantity
      - i.blocked_quantity
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
-- 4. AUTOMATIC CYCLE CREATION UPON CLOSING A POINT
-- =========================================================

CREATE OR REPLACE FUNCTION create_storage_point_closure_cycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'closed'
     AND OLD.status <> 'closed' THEN

    INSERT INTO storage_point_closure_cycles (
      storage_point_id,
      closed_at,
      closed_by,
      closure_reason
    )
    VALUES (
      NEW.id,
      NOW(),
      NULL,
      'Закриття складської точки'
    )
    ON CONFLICT (storage_point_id)
      WHERE reopened_at IS NULL
    DO NOTHING;

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_create_closure_cycle
AFTER UPDATE OF status
ON storage_points
FOR EACH ROW
EXECUTE FUNCTION create_storage_point_closure_cycle();


-- =========================================================
-- 5. CREATING CYCLES FOR ALREADY CLOSED POINTS
-- =========================================================

INSERT INTO storage_point_closure_cycles (
  storage_point_id,
  closed_at,
  closure_reason
)
SELECT
  sp.id,
  NOW(),
  'Початковий цикл для вже закритої точки'
FROM storage_points sp
WHERE sp.status = 'closed'
  AND NOT EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles c
    WHERE c.storage_point_id = sp.id
      AND c.reopened_at IS NULL
  )
ON CONFLICT (storage_point_id)
  WHERE reopened_at IS NULL
DO NOTHING;


-- =========================================================
-- 6. REPORTING ACCESSIBILITY NON-COMPLIANCE
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