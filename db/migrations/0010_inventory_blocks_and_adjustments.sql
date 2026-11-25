-- =========================================================
-- 1. ADDITIONAL FIELDS AND IDEMPOTENCY
-- =========================================================

ALTER TABLE inventory_blocks
ADD COLUMN IF NOT EXISTS comment TEXT,
ADD COLUMN IF NOT EXISTS operation_key UUID;

CREATE UNIQUE INDEX IF NOT EXISTS
  inventory_blocks_operation_key_unique
ON inventory_blocks(operation_key)
WHERE operation_key IS NOT NULL;


ALTER TABLE inventory_block_movements
ADD COLUMN IF NOT EXISTS operation_key UUID;

CREATE UNIQUE INDEX IF NOT EXISTS
  inventory_block_movements_operation_key_unique
ON inventory_block_movements(operation_key)
WHERE operation_key IS NOT NULL;


ALTER TABLE inventory_movements
ADD COLUMN IF NOT EXISTS operation_key UUID,
ADD COLUMN IF NOT EXISTS accounting_act_number TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS
  inventory_movements_operation_key_unique
ON inventory_movements(operation_key)
WHERE operation_key IS NOT NULL;


-- =========================================================
-- 2. BLOCK INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION block_inventory(
  p_inventory_id UUID,
  p_quantity INTEGER,
  p_reason TEXT,
  p_user_id UUID,
  p_operation_key UUID,
  p_reservation_releases JSONB DEFAULT '[]'::JSONB,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
  v_block_id UUID;
  v_available INTEGER;
  v_required_release INTEGER;
  v_selected_release INTEGER := 0;
  v_release RECORD;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість для блокування повинна бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_reason NOT IN (
    'damage',
    'suspected_damage',
    'loss',
    'other'
  ) THEN
    RAISE EXCEPTION 'Невідома причина блокування';
  END IF;

  IF p_reason = 'other'
     AND NULLIF(TRIM(p_comment), '') IS NULL THEN
    RAISE EXCEPTION
      'Для причини other необхідно додати коментар';
  END IF;

  IF p_reservation_releases IS NULL
     OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
    RAISE EXCEPTION
      'Перелік вивільнення резервів повинен бути масивом';
  END IF;

  -- Idempotency check.
  SELECT id
  INTO v_block_id
  FROM inventory_blocks
  WHERE operation_key = p_operation_key;

  IF v_block_id IS NOT NULL THEN
    RETURN v_block_id;
  END IF;

  -- Lock inventory.
  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис залишку не знайдено';
  END IF;

  v_available :=
    v_inventory.quantity
    - v_inventory.reserved_quantity
    - v_inventory.blocked_quantity;

  v_required_release := GREATEST(
    0,
    p_quantity - v_available
  );

  -- Validate selected releases.
  SELECT COALESCE(SUM((item->>'quantity')::INTEGER), 0)
  INTO v_selected_release
  FROM jsonb_array_elements(p_reservation_releases) AS item;

  IF v_selected_release <> v_required_release THEN
    RAISE EXCEPTION
      'Необхідно явно вибрати резерви на кількість %. Вибрано: %',
      v_required_release,
      v_selected_release;
  END IF;

  -- Validate entries and reject duplicate reservation IDs.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_reservation_releases) AS item
    WHERE
      NULLIF(item->>'reservation_id', '') IS NULL
      OR NULLIF(item->>'quantity', '') IS NULL
      OR (item->>'quantity')::INTEGER <= 0
  ) THEN
    RAISE EXCEPTION 'Некоректні дані вибраного резерву';
  END IF;

  IF EXISTS (
    SELECT (item->>'reservation_id')::UUID
    FROM jsonb_array_elements(p_reservation_releases) AS item
    GROUP BY (item->>'reservation_id')::UUID
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Один резерв не може бути зазначений декілька разів';
  END IF;

  -- Explicitly release selected reservations.
  FOR v_release IN
    SELECT
      (item->>'reservation_id')::UUID AS reservation_id,
      (item->>'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(p_reservation_releases) AS item
  LOOP
    PERFORM release_inventory_reservation(
      v_release.reservation_id,
      v_release.quantity,
      'inventory_block',
      'inventory_block',
      p_inventory_id,
      p_user_id,
      gen_random_uuid()
    );
  END LOOP;

  -- Re-read inventory after releases.
  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  v_available :=
    v_inventory.quantity
    - v_inventory.reserved_quantity
    - v_inventory.blocked_quantity;

  IF v_available < p_quantity THEN
    RAISE EXCEPTION
      'Недостатньо доступного товару для блокування';
  END IF;

  -- Create block.
  INSERT INTO inventory_blocks (
    inventory_id,
    reason,
    initial_quantity,
    unblocked_quantity,
    created_by,
    comment,
    operation_key
  )
  VALUES (
    p_inventory_id,
    p_reason,
    p_quantity,
    0,
    p_user_id,
    p_comment,
    p_operation_key
  )
  RETURNING id INTO v_block_id;

  -- Update inventory balance.
  UPDATE inventory
  SET blocked_quantity = blocked_quantity + p_quantity
  WHERE id = p_inventory_id;

  -- Record block movement.
  INSERT INTO inventory_block_movements (
    block_id,
    movement_type,
    quantity,
    reference_type,
    reference_id,
    reason,
    created_by,
    operation_key
  )
  VALUES (
    v_block_id,
    'block',
    p_quantity,
    'inventory_block',
    v_block_id,
    COALESCE(NULLIF(TRIM(p_comment), ''), p_reason),
    p_user_id,
    p_operation_key
  );

  RETURN v_block_id;
END;
$$;


-- =========================================================
-- 3. UNBLOCK INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION unblock_inventory(
  p_block_id UUID,
  p_quantity INTEGER,
  p_reason TEXT,
  p_user_id UUID,
  p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_movement_id UUID;
  v_remaining INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість для розблокування повинна бути більшою за нуль';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION
      'Причина розблокування є обов’язковою';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  -- Idempotency check.
  SELECT id
  INTO v_movement_id
  FROM inventory_block_movements
  WHERE operation_key = p_operation_key;

  IF v_movement_id IS NOT NULL THEN
    RETURN v_movement_id;
  END IF;

  -- Lock block and linked inventory.
  SELECT
    b.*,
    i.id AS linked_inventory_id
  INTO v_block
  FROM inventory_blocks b
  JOIN inventory i ON i.id = b.inventory_id
  WHERE b.id = p_block_id
  FOR UPDATE OF b, i;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування не знайдено';
  END IF;

  v_remaining :=
    v_block.initial_quantity - v_block.unblocked_quantity;

  IF p_quantity > v_remaining THEN
    RAISE EXCEPTION
      'Кількість перевищує залишок заблокованого товару';
  END IF;

  UPDATE inventory_blocks
  SET unblocked_quantity = unblocked_quantity + p_quantity
  WHERE id = p_block_id;

  UPDATE inventory
  SET blocked_quantity = blocked_quantity - p_quantity
  WHERE id = v_block.inventory_id
    AND blocked_quantity >= p_quantity;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Некоректний баланс заблокованого товару';
  END IF;

  -- Record unblock movement.
  INSERT INTO inventory_block_movements (
    block_id,
    movement_type,
    quantity,
    reference_type,
    reference_id,
    reason,
    created_by,
    operation_key
  )
  VALUES (
    p_block_id,
    'unblock',
    p_quantity,
    'inventory_block',
    p_block_id,
    p_reason,
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 4. ADJUST INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION adjust_inventory(
  p_inventory_id UUID,
  p_actual_quantity INTEGER,
  p_reason TEXT,
  p_user_id UUID,
  p_operation_key UUID,
  p_reservation_releases JSONB DEFAULT '[]'::JSONB,
  p_accounting_act_number TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_inventory RECORD;
  v_movement_id UUID;
  v_difference INTEGER;
  v_shortage INTEGER;
  v_available INTEGER;
  v_required_release INTEGER;
  v_selected_release INTEGER := 0;
  v_release RECORD;
BEGIN
  IF p_actual_quantity IS NULL OR p_actual_quantity < 0 THEN
    RAISE EXCEPTION
      'Фактична кількість не може бути від’ємною';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION
      'Причина коригування є обов’язковою';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_reservation_releases IS NULL
     OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
    RAISE EXCEPTION
      'Перелік вивільнення резервів повинен бути масивом';
  END IF;

  -- Idempotency check.
  SELECT id
  INTO v_movement_id
  FROM inventory_movements
  WHERE operation_key = p_operation_key;

  IF v_movement_id IS NOT NULL THEN
    RETURN v_movement_id;
  END IF;

  -- Lock inventory.
  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис залишку не знайдено';
  END IF;

  v_difference :=
    p_actual_quantity - v_inventory.quantity;

  IF v_difference = 0 THEN
    RAISE EXCEPTION
      'Фактична кількість відповідає обліковій. Коригування не потрібне';
  END IF;

  -- Negative adjustment requires accounting act.
  IF v_difference < 0
     AND NULLIF(TRIM(p_accounting_act_number), '') IS NULL THEN
    RAISE EXCEPTION
      'Для негативного коригування необхідний номер бухгалтерського акта';
  END IF;

  IF v_difference < 0 THEN
    v_shortage := ABS(v_difference);

    v_available :=
      v_inventory.quantity
      - v_inventory.reserved_quantity
      - v_inventory.blocked_quantity;

    v_required_release := GREATEST(
      0,
      v_shortage - v_available
    );

    SELECT COALESCE(SUM((item->>'quantity')::INTEGER), 0)
    INTO v_selected_release
    FROM jsonb_array_elements(p_reservation_releases) AS item;

    IF v_selected_release <> v_required_release THEN
      RAISE EXCEPTION
        'Необхідно явно вибрати резерви для вивільнення на кількість %. Вибрано: %',
        v_required_release,
        v_selected_release;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_reservation_releases) AS item
      WHERE
        NULLIF(item->>'reservation_id', '') IS NULL
        OR NULLIF(item->>'quantity', '') IS NULL
        OR (item->>'quantity')::INTEGER <= 0
    ) THEN
      RAISE EXCEPTION 'Некоректні дані вибраного резерву';
    END IF;

    IF EXISTS (
      SELECT (item->>'reservation_id')::UUID
      FROM jsonb_array_elements(p_reservation_releases) AS item
      GROUP BY (item->>'reservation_id')::UUID
      HAVING COUNT(*) > 1
    ) THEN
      RAISE EXCEPTION
        'Один резерв не може бути зазначений декілька разів';
    END IF;

    -- Explicitly release selected reservations.
    FOR v_release IN
      SELECT
        (item->>'reservation_id')::UUID AS reservation_id,
        (item->>'quantity')::INTEGER AS quantity
      FROM jsonb_array_elements(p_reservation_releases) AS item
    LOOP
      PERFORM release_inventory_reservation(
        v_release.reservation_id,
        v_release.quantity,
        'inventory_adjustment',
        'inventory',
        p_inventory_id,
        p_user_id,
        gen_random_uuid()
      );
    END LOOP;

    -- Refresh inventory after reservation releases.
    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    IF p_actual_quantity <
       v_inventory.reserved_quantity + v_inventory.blocked_quantity THEN
      RAISE EXCEPTION
        'Фактична кількість нижча за суму резервів і блокувань. Спочатку необхідно врегулювати заблокований товар';
    END IF;
  END IF;

  -- Set actual physical quantity.
  UPDATE inventory
  SET quantity = p_actual_quantity
  WHERE id = p_inventory_id;

  -- Record adjustment.
  INSERT INTO inventory_movements (
    inventory_id,
    movement_type,
    quantity,
    quantity_before,
    quantity_after,
    reference_type,
    reference_id,
    reason,
    accounting_act_number,
    created_by,
    operation_key
  )
  VALUES (
    p_inventory_id,
    'adjustment',
    ABS(v_difference),
    v_inventory.quantity,
    p_actual_quantity,
    'inventory_adjustment',
    p_inventory_id,
    p_reason,
    p_accounting_act_number,
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;