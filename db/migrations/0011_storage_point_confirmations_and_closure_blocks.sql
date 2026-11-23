-- =========================================================
-- 1. CONFIRMATION OF TRANSACTIONS FOR UNAVAILABLE POINTS
-- =========================================================

CREATE TABLE storage_point_operation_confirmations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  operation_type TEXT NOT NULL,
  operation_id UUID NOT NULL,

  confirmed_by UUID NOT NULL
    REFERENCES employees(id),

  confirmed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  comment TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT storage_point_operation_confirmation_unique
    UNIQUE (
      storage_point_id,
      operation_type,
      operation_id
    )
);

CREATE INDEX storage_point_confirmations_operation_idx
ON storage_point_operation_confirmations(
  operation_type,
  operation_id
);


-- =========================================================
-- 2. CONFIRMATION ONLY FROM AN ACTIVE RESPONSIBLE PERSON
-- =========================================================

CREATE OR REPLACE FUNCTION validate_storage_point_confirmation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
  v_is_responsible BOOLEAN;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = NEW.storage_point_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_status <> 'unavailable' THEN
    RAISE EXCEPTION
      'Підтвердження потрібне лише для точки зі статусом unavailable';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM storage_point_responsibles spr
    JOIN employees e ON e.id = spr.employee_id
    WHERE spr.storage_point_id = NEW.storage_point_id
      AND spr.employee_id = NEW.confirmed_by
      AND spr.valid_from <= NOW()
      AND (spr.valid_until IS NULL OR spr.valid_until > NOW())
      AND e.is_active = TRUE
  )
  INTO v_is_responsible;

  IF NOT v_is_responsible THEN
    RAISE EXCEPTION
      'Підтвердити операцію може лише активна відповідальна особа цієї точки';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_confirmation_validation
BEFORE INSERT ON storage_point_operation_confirmations
FOR EACH ROW
EXECUTE FUNCTION validate_storage_point_confirmation();


-- =========================================================
-- 3. THE CONFIRMATION LOG CANNOT BE EDITED OR DELETED
-- =========================================================

CREATE TRIGGER storage_point_confirmations_immutable
BEFORE UPDATE OR DELETE ON storage_point_operation_confirmations
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 4. BLOCKING OF BALANCES FOR A CLOSED LOCATION
-- =========================================================

CREATE TABLE storage_point_closure_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  product_id UUID NOT NULL
    REFERENCES products(id),

  initial_quantity INTEGER NOT NULL,

  released_quantity INTEGER NOT NULL DEFAULT 0,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  created_by UUID NOT NULL
    REFERENCES users(id),

  CONSTRAINT closure_block_initial_quantity_positive
    CHECK (initial_quantity >= 0),

  CONSTRAINT closure_block_released_quantity_valid
    CHECK (
      released_quantity >= 0
      AND released_quantity <= initial_quantity
    )
);

CREATE UNIQUE INDEX storage_point_closure_blocks_point_product_unique
ON storage_point_closure_blocks(
  storage_point_id,
  product_id
);


-- =========================================================
-- 5. LOG OF GOODS CHECKS AFTER CLOSING
-- =========================================================

CREATE TABLE storage_point_closure_inspections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  closure_block_id UUID NOT NULL
    REFERENCES storage_point_closure_blocks(id),

  inspected_quantity INTEGER NOT NULL,

  suitable_quantity INTEGER NOT NULL,

  inspected_by UUID NOT NULL
    REFERENCES employees(id),

  comment TEXT,

  inspected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT closure_inspection_quantities_valid
    CHECK (
      inspected_quantity >= 0
      AND suitable_quantity >= 0
      AND suitable_quantity <= inspected_quantity
    )
);

CREATE INDEX storage_point_closure_inspections_block_idx
ON storage_point_closure_inspections(closure_block_id);


-- =========================================================
-- 6. LOG OF PARTIAL REMOVAL OF CLOSING BLOCK
-- =========================================================

CREATE TABLE storage_point_closure_block_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  closure_block_id UUID NOT NULL
    REFERENCES storage_point_closure_blocks(id),

  movement_type TEXT NOT NULL
    CHECK (movement_type IN ('block', 'release')),

  quantity INTEGER NOT NULL
    CHECK (quantity > 0),

  inspection_id UUID
    REFERENCES storage_point_closure_inspections(id),

  reference_type TEXT,
  reference_id UUID,

  reason TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX closure_block_movements_block_idx
ON storage_point_closure_block_movements(closure_block_id);


CREATE TRIGGER closure_inspections_immutable
BEFORE UPDATE OR DELETE ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER closure_block_movements_immutable
BEFORE UPDATE OR DELETE ON storage_point_closure_block_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 7. FUNCTION FOR RECORDING BALANCES UPON CLOSING A POINT OF SALE
-- =========================================================

CREATE OR REPLACE FUNCTION create_storage_point_closure_blocks(
  p_storage_point_id UUID,
  p_user_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
  v_inventory RECORD;
  v_count INTEGER := 0;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = p_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_status <> 'closed' THEN
    RAISE EXCEPTION
      'Блокування залишків можливе лише після закриття точки';
  END IF;

  FOR v_inventory IN
    SELECT *
    FROM inventory
    WHERE storage_point_id = p_storage_point_id
    FOR UPDATE
  LOOP
    INSERT INTO storage_point_closure_blocks (
      storage_point_id,
      product_id,
      initial_quantity,
      released_quantity,
      created_by
    )
    VALUES (
      p_storage_point_id,
      v_inventory.product_id,
      v_inventory.quantity,
      0,
      p_user_id
    )
    ON CONFLICT (storage_point_id, product_id)
    DO NOTHING;

    IF FOUND THEN
      INSERT INTO storage_point_closure_block_movements (
        closure_block_id,
        movement_type,
        quantity,
        reason,
        created_by
      )
      SELECT
        id,
        'block',
        initial_quantity,
        'storage_point_closed',
        p_user_id
      FROM storage_point_closure_blocks
      WHERE storage_point_id = p_storage_point_id
        AND product_id = v_inventory.product_id;

      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;


-- =========================================================
-- 8. PRODUCT VERIFICATION FUNCTION AFTER CLOSING
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
  v_block RECORD;
  v_inspection_id UUID;
  v_is_responsible BOOLEAN;
BEGIN
  IF p_inspected_quantity < 0
     OR p_suitable_quantity < 0
     OR p_suitable_quantity > p_inspected_quantity THEN
    RAISE EXCEPTION 'Некоректні кількості під час перевірки';
  END IF;

  SELECT cb.*
  INTO v_block
  FROM storage_point_closure_blocks cb
  WHERE cb.id = p_closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування закриття не знайдено';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM storage_point_responsibles spr
    JOIN employees e ON e.id = spr.employee_id
    WHERE spr.storage_point_id = v_block.storage_point_id
      AND spr.employee_id = p_employee_id
      AND spr.valid_from <= NOW()
      AND (spr.valid_until IS NULL OR spr.valid_until > NOW())
      AND e.is_active = TRUE
  )
  INTO v_is_responsible;

  IF NOT v_is_responsible THEN
    RAISE EXCEPTION
      'Перевірку може виконати лише активна відповідальна особа точки';
  END IF;

  INSERT INTO storage_point_closure_inspections (
    closure_block_id,
    inspected_quantity,
    suitable_quantity,
    inspected_by,
    comment
  )
  VALUES (
    p_closure_block_id,
    p_inspected_quantity,
    p_suitable_quantity,
    p_employee_id,
    p_comment
  )
  RETURNING id INTO v_inspection_id;

  RETURN v_inspection_id;
END;
$$;


-- =========================================================
-- 9. PARTIAL UNLOCKING FUNCTION
-- =========================================================


CREATE OR REPLACE FUNCTION release_storage_point_closure_block(
  p_closure_block_id UUID,
  p_quantity INTEGER,
  p_inspection_id UUID,
  p_user_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_inspection RECORD;
  v_released_from_inspection INTEGER;
  v_movement_id UUID;
  v_remaining INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість для зняття блокування має бути більшою за нуль';
  END IF;

  SELECT *
  INTO v_block
  FROM storage_point_closure_blocks
  WHERE id = p_closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування закриття не знайдено';
  END IF;

  SELECT *
  INTO v_inspection
  FROM storage_point_closure_inspections
  WHERE id = p_inspection_id
    AND closure_block_id = p_closure_block_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Перевірку товару не знайдено';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_released_from_inspection
  FROM storage_point_closure_block_movements
  WHERE inspection_id = p_inspection_id
    AND movement_type = 'release';

  IF v_released_from_inspection + p_quantity >
     v_inspection.suitable_quantity THEN
    RAISE EXCEPTION
      'Кількість перевищує придатний залишок за результатами перевірки';
  END IF;

  v_remaining :=
    v_block.initial_quantity - v_block.released_quantity;

  IF p_quantity > v_remaining THEN
    RAISE EXCEPTION 'Кількість перевищує залишок блокування закриття';
  END IF;

  UPDATE storage_point_closure_blocks
  SET released_quantity = released_quantity + p_quantity
  WHERE id = p_closure_block_id;

  INSERT INTO storage_point_closure_block_movements (
    closure_block_id,
    movement_type,
    quantity,
    inspection_id,
    reason,
    created_by
  )
  VALUES (
    p_closure_block_id,
    'release',
    p_quantity,
    p_inspection_id,
    COALESCE(NULLIF(TRIM(p_reason), ''), 'inspection_approved'),
    p_user_id
  )
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;