-- =========================================================
-- 1. ASSIGN CLOSURE CYCLE TO INVENTORY BLOCKS
-- =========================================================

CREATE OR REPLACE FUNCTION assign_closure_cycle_to_block()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
BEGIN
  SELECT
    id,
    storage_point_id,
    product_id
  INTO v_inventory
  FROM inventory
  WHERE id = NEW.inventory_id
  FOR KEY SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
  END IF;

  NEW.storage_point_id := v_inventory.storage_point_id;
  NEW.product_id := v_inventory.product_id;

  IF NEW.closure_cycle_id IS NULL THEN
    SELECT id
    INTO NEW.closure_cycle_id
    FROM storage_point_closure_cycles
    WHERE storage_point_id = NEW.storage_point_id
      AND reopened_at IS NULL
    ORDER BY closed_at DESC
    LIMIT 1;
  END IF;

  IF NEW.closure_cycle_id IS NULL THEN
    RAISE EXCEPTION 'ACTIVE_CLOSURE_CYCLE_NOT_FOUND';
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

DROP TRIGGER IF EXISTS storage_point_closure_block_cycle_guard
ON storage_point_closure_blocks;

DROP TRIGGER IF EXISTS a_storage_point_closure_block_cycle_guard
ON storage_point_closure_blocks;

CREATE TRIGGER a_storage_point_closure_block_cycle_guard
BEFORE INSERT
ON storage_point_closure_blocks
FOR EACH ROW
EXECUTE FUNCTION assign_closure_cycle_to_block();


-- =========================================================
-- 2. START A STORAGE POINT CLOSURE CYCLE
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
  v_inventory RECORD;
  v_initial_quantity BIGINT;
  v_existing_closure_quantity BIGINT;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = p_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
  END IF;

  IF v_status <> 'closed' THEN
    RAISE EXCEPTION 'STORAGE_POINT_MUST_BE_CLOSED';
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
    closed_at,
    closure_reason
  )
  VALUES (
    p_storage_point_id,
    NOW(),
    'storage_point_closed'
  )
  RETURNING id INTO v_cycle_id;

  FOR v_inventory IN
    SELECT
      i.id,
      i.storage_point_id,
      i.product_id,
      i.quantity,
      i.reserved_quantity,
      i.blocked_quantity
    FROM inventory i
    WHERE i.storage_point_id = p_storage_point_id
    ORDER BY i.id
    FOR UPDATE
  LOOP
    SELECT COALESCE(
      SUM(
        cb.initial_quantity::BIGINT
        - cb.released_quantity::BIGINT
      ),
      0
    )
    INTO v_existing_closure_quantity
    FROM storage_point_closure_blocks cb
    WHERE cb.inventory_id = v_inventory.id
      AND cb.initial_quantity > cb.released_quantity;

    v_initial_quantity := GREATEST(
      v_inventory.quantity::BIGINT
      - v_inventory.reserved_quantity::BIGINT
      - v_inventory.blocked_quantity::BIGINT
      - v_existing_closure_quantity,
      0
    );

    IF v_initial_quantity > 0 THEN
      INSERT INTO storage_point_closure_blocks (
        closure_id,
        closure_cycle_id,
        storage_point_id,
        inventory_id,
        product_id,
        initial_quantity,
        released_quantity,
        created_by
      )
      VALUES (
        NULL,
        v_cycle_id,
        v_inventory.storage_point_id,
        v_inventory.id,
        v_inventory.product_id,
        v_initial_quantity,
        0,
        NULL
      )
      ON CONFLICT (closure_cycle_id, product_id)
      DO NOTHING;
    END IF;
  END LOOP;

  RETURN v_cycle_id;
END;
$$;


-- =========================================================
-- 3. AUTOMATIC CLOSURE CYCLE CREATION
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

DROP TRIGGER IF EXISTS storage_point_start_closure_cycle
ON storage_points;

DROP TRIGGER IF EXISTS storage_point_create_closure_cycle
ON storage_points;

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
-- 4. REMOVE THE PREVIOUS RECLOSURE RESTRICTION
-- =========================================================

DROP TRIGGER IF EXISTS storage_point_closure_reopen_guard
ON storage_points;


-- =========================================================
-- 5. VALIDATE INVENTORY RESERVATIONS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_reservation_closure()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_storage_point_id UUID;
  v_point_status TEXT;
  v_inventory RECORD;

  v_reserved_total BIGINT;
  v_new_remaining BIGINT;
  v_old_remaining BIGINT;
  v_closure_blocked BIGINT;
  v_available BIGINT;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.inventory_id <> NEW.inventory_id THEN
    RAISE EXCEPTION 'RESERVATION_INVENTORY_CANNOT_CHANGE';
  END IF;

  SELECT storage_point_id
  INTO v_storage_point_id
  FROM inventory
  WHERE id = NEW.inventory_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_point_status
  FROM storage_points
  WHERE id = v_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
  END IF;

  SELECT
    id,
    storage_point_id,
    product_id,
    quantity,
    blocked_quantity
  INTO v_inventory
  FROM inventory
  WHERE id = NEW.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
  END IF;

  v_new_remaining :=
    NEW.reserved_quantity::BIGINT
    - NEW.consumed_quantity::BIGINT
    - NEW.released_quantity::BIGINT;

  IF v_new_remaining < 0 THEN
    RAISE EXCEPTION 'INVALID_RESERVATION_BALANCE';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_old_remaining :=
      OLD.reserved_quantity::BIGINT
      - OLD.consumed_quantity::BIGINT
      - OLD.released_quantity::BIGINT;
  ELSE
    v_old_remaining := 0;
  END IF;

  IF v_point_status = 'closed' THEN
    IF TG_OP = 'INSERT' THEN
      RAISE EXCEPTION 'RESERVATION_NOT_ALLOWED_FOR_CLOSED_STORAGE_POINT';
    END IF;

    IF NEW.reserved_quantity <> OLD.reserved_quantity
       OR NEW.consumed_quantity <> OLD.consumed_quantity
       OR NEW.released_quantity < OLD.released_quantity
       OR v_new_remaining > v_old_remaining THEN
      RAISE EXCEPTION 'ONLY_RESERVATION_RELEASE_ALLOWED_FOR_CLOSED_STORAGE_POINT';
    END IF;

    RETURN NEW;
  END IF;

  SELECT COALESCE(
    SUM(
      r.reserved_quantity::BIGINT
      - r.consumed_quantity::BIGINT
      - r.released_quantity::BIGINT
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

  v_reserved_total := v_reserved_total + v_new_remaining;

  v_closure_blocked :=
    get_storage_point_closure_blocked_quantity(
      v_inventory.storage_point_id,
      v_inventory.product_id
    );

  v_available :=
    v_inventory.quantity::BIGINT
    - v_inventory.blocked_quantity::BIGINT
    - v_closure_blocked;

  IF v_reserved_total > v_available THEN
    RAISE EXCEPTION 'INSUFFICIENT_EFFECTIVE_INVENTORY_FOR_RESERVATION';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS inventory_reservation_closure_guard
ON inventory_reservations;

CREATE TRIGGER inventory_reservation_closure_guard
BEFORE INSERT OR UPDATE
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_reservation_closure();


-- =========================================================
-- 6. IMMUTABLE CLOSURE CYCLE HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closure_cycle_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_HISTORY_CANNOT_BE_DELETED';
  END IF;

  IF OLD.storage_point_id IS DISTINCT FROM NEW.storage_point_id
     OR OLD.closed_at IS DISTINCT FROM NEW.closed_at
     OR OLD.closed_by IS DISTINCT FROM NEW.closed_by
     OR OLD.closure_reason IS DISTINCT FROM NEW.closure_reason
     OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_ORIGINAL_DATA_IS_IMMUTABLE';
  END IF;

  IF OLD.reopened_at IS NOT NULL
     OR OLD.reopened_by IS NOT NULL
     OR OLD.reopening_reason IS NOT NULL THEN
    RAISE EXCEPTION 'CLOSURE_CYCLE_ALREADY_REOPENED';
  END IF;

  IF NEW.reopened_at IS NULL
     OR NEW.reopened_by IS NULL
     OR NEW.reopening_reason IS NULL
     OR BTRIM(NEW.reopening_reason) = '' THEN
    RAISE EXCEPTION 'INVALID_CLOSURE_CYCLE_REOPENING_DATA';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS storage_point_closure_cycle_immutable
ON storage_point_closure_cycles;

CREATE TRIGGER storage_point_closure_cycle_immutable
BEFORE UPDATE OR DELETE
ON storage_point_closure_cycles
FOR EACH ROW
EXECUTE FUNCTION prevent_closure_cycle_mutation();


-- =========================================================
-- 7. CLOSURE BLOCK INTEGRITY VIEW
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_integrity AS
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