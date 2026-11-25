-- =========================================================
-- 1. CREATING A CLOSURE AND LOCKOUT CYCLE
-- =========================================================

CREATE OR REPLACE FUNCTION start_storage_point_closure_cycle(
  p_storage_point_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_cycle_id UUID;
  v_status TEXT;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = p_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Складську точку не знайдено';
  END IF;

  IF v_status <> 'closed' THEN
    RAISE EXCEPTION
      'Цикл закриття можна створити лише для закритої точки';
  END IF;

  SELECT id
  INTO v_cycle_id
  FROM storage_point_closure_cycles
  WHERE storage_point_id = p_storage_point_id
    AND reopened_at IS NULL
  LIMIT 1;

  IF v_cycle_id IS NOT NULL THEN
    RETURN v_cycle_id;
  END IF;

  INSERT INTO storage_point_closure_cycles (
    storage_point_id,
    closed_at
  )
  VALUES (
    p_storage_point_id,
    NOW()
  )
  RETURNING id INTO v_cycle_id;

  INSERT INTO storage_point_closure_blocks (
    storage_point_id,
    product_id,
    closure_cycle_id,
    initial_quantity,
    released_quantity,
    created_by
  )
  SELECT
    i.storage_point_id,
    i.product_id,
    v_cycle_id,
    GREATEST(
      i.quantity - i.reserved_quantity - i.blocked_quantity,
      0
    ),
    0,
    NULL
  FROM inventory i
  WHERE i.storage_point_id = p_storage_point_id
    AND i.quantity - i.reserved_quantity - i.blocked_quantity > 0
  ON CONFLICT (closure_cycle_id, product_id)
  DO NOTHING;

  RETURN v_cycle_id;
END;
$$;


-- =========================================================
-- 2. AUTOMATIC CYCLE START UPON CLOSING
-- =========================================================

CREATE OR REPLACE FUNCTION handle_storage_point_closure()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'closed'
     AND OLD.status <> 'closed' THEN

    PERFORM start_storage_point_closure_cycle(NEW.id);

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_start_closure_cycle
AFTER UPDATE OF status
ON storage_points
FOR EACH ROW
WHEN (
  OLD.status <> 'closed'
  AND NEW.status = 'closed'
)
EXECUTE FUNCTION handle_storage_point_closure();


-- =========================================================
-- 3. FUNCTION FOR CALCULATING REMAINING BLOCKING CYCLES
-- =========================================================

CREATE OR REPLACE FUNCTION get_active_closure_block_quantity(
  p_storage_point_id UUID,
  p_product_id UUID
)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    SUM(b.initial_quantity - b.released_quantity),
    0
  )::INTEGER
  FROM storage_point_closure_blocks b
  WHERE b.storage_point_id = p_storage_point_id
    AND b.product_id = p_product_id
    AND b.initial_quantity > b.released_quantity;
$$;


-- =========================================================
-- 4. AVAILABILITY CHECK DURING RESERVATION CREATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_reservation_closure()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
  v_reserved_total BIGINT;
  v_closure_blocked BIGINT;
  v_new_remaining BIGINT;
  v_available BIGINT;
  v_point_status TEXT;
BEGIN
  SELECT
    i.id,
    i.storage_point_id,
    i.product_id,
    i.quantity,
    i.blocked_quantity
  INTO v_inventory
  FROM inventory i
  WHERE i.id = NEW.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис залишку не знайдено';
  END IF;

  SELECT status
  INTO v_point_status
  FROM storage_points
  WHERE id = v_inventory.storage_point_id
  FOR UPDATE;

  IF v_point_status IS NULL THEN
    RAISE EXCEPTION 'Складську точку не знайдено';
  END IF;

  IF v_point_status = 'closed'
     AND NEW.salvage_request_item_id IS NULL THEN
    RAISE EXCEPTION
      'Звичайне резервування із закритої точки заборонене';
  END IF;

  SELECT COALESCE(
    SUM(
      r.reserved_quantity
      - r.consumed_quantity
      - r.released_quantity
    ),
    0
  )
  INTO v_reserved_total
  FROM inventory_reservations r
  WHERE r.inventory_id = NEW.inventory_id
    AND (
      TG_OP = 'INSERT'
      OR r.id <> NEW.id
    );

  v_new_remaining :=
    NEW.reserved_quantity
    - NEW.consumed_quantity
    - NEW.released_quantity;

  IF v_new_remaining < 0 THEN
    RAISE EXCEPTION
      'Залишок резерву не може бути від’ємним';
  END IF;

  v_reserved_total := v_reserved_total + v_new_remaining;

  v_closure_blocked := get_active_closure_block_quantity(
    v_inventory.storage_point_id,
    v_inventory.product_id
  );

  v_available :=
    v_inventory.quantity
    - v_inventory.blocked_quantity
    - v_closure_blocked;

  IF v_reserved_total > v_available THEN
    RAISE EXCEPTION
      'Недостатньо доступного товару: частина залишку ще заблокована після закриття точки';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_reservation_closure_guard
BEFORE INSERT OR UPDATE
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_reservation_closure();


-- =========================================================
-- 5. PROHIBITION OF MANUAL ALTERATION OF CLOSING CYCLES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closure_cycle_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Історію циклів закриття не можна видаляти';
  END IF;

  IF OLD.storage_point_id <> NEW.storage_point_id
     OR OLD.closed_at <> NEW.closed_at
     OR OLD.closed_by IS DISTINCT FROM NEW.closed_by THEN
    RAISE EXCEPTION
      'Початкові дані циклу закриття не можна змінювати';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_cycle_immutable
BEFORE UPDATE OR DELETE
ON storage_point_closure_cycles
FOR EACH ROW
EXECUTE FUNCTION prevent_closure_cycle_mutation();


-- =========================================================
-- 6. INTERLOCK INTEGRITY MONITORING
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_integrity AS
SELECT
  b.id AS closure_block_id,
  b.closure_cycle_id,
  b.storage_point_id,
  b.product_id,

  b.initial_quantity,
  b.released_quantity,

  b.initial_quantity - b.released_quantity
    AS remaining_quantity,

  CASE
    WHEN b.released_quantity > b.initial_quantity
      THEN FALSE
    WHEN b.released_quantity < 0
      THEN FALSE
    ELSE TRUE
  END AS is_valid

FROM storage_point_closure_blocks b;