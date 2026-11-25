-- =========================================================
-- 1. WAREHOUSE LOCATION CLOSURE CYCLES
-- =========================================================

CREATE TABLE storage_point_closure_cycles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  closed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  closed_by UUID REFERENCES users(id),

  reopened_at TIMESTAMPTZ,

  reopened_by UUID REFERENCES users(id),

  closure_reason TEXT,

  reopening_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT closure_cycle_reopening_check
    CHECK (
      (reopened_at IS NULL AND reopened_by IS NULL)
      OR
      (reopened_at IS NOT NULL AND reopened_by IS NOT NULL)
    ),

  CONSTRAINT closure_cycle_reason_check
    CHECK (
      closure_reason IS NULL
      OR LENGTH(closure_reason) <= 2000
    ),

  CONSTRAINT closure_cycle_reopening_reason_check
    CHECK (
      reopening_reason IS NULL
      OR LENGTH(reopening_reason) <= 2000
    )
);

CREATE UNIQUE INDEX storage_point_one_open_closure_cycle_idx
  ON storage_point_closure_cycles(storage_point_id)
  WHERE reopened_at IS NULL;

CREATE INDEX storage_point_closure_cycles_history_idx
  ON storage_point_closure_cycles(storage_point_id, closed_at DESC);


-- =========================================================
-- 2. LINKING LOCKS TO A SPECIFIC CYCLE
-- =========================================================

ALTER TABLE storage_point_closure_blocks
  ADD COLUMN closure_cycle_id UUID
  REFERENCES storage_point_closure_cycles(id);

ALTER TABLE storage_point_closure_blocks
  DROP CONSTRAINT IF EXISTS
    storage_point_closure_blocks_storage_point_id_product_id_key;

INSERT INTO storage_point_closure_cycles (
  storage_point_id,
  closed_at,
  closure_reason
)
SELECT DISTINCT
  b.storage_point_id,
  b.created_at,
  'Історичний цикл закриття'
FROM storage_point_closure_blocks b
WHERE b.closure_cycle_id IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles c
    WHERE c.storage_point_id = b.storage_point_id
      AND c.reopened_at IS NULL
  );

UPDATE storage_point_closure_blocks b
SET closure_cycle_id = (
  SELECT c.id
  FROM storage_point_closure_cycles c
  WHERE c.storage_point_id = b.storage_point_id
  ORDER BY c.closed_at DESC
  LIMIT 1
)
WHERE b.closure_cycle_id IS NULL;

ALTER TABLE storage_point_closure_blocks
  ALTER COLUMN closure_cycle_id SET NOT NULL;

CREATE UNIQUE INDEX storage_point_closure_cycle_product_idx
  ON storage_point_closure_blocks(closure_cycle_id, product_id);


-- =========================================================
-- 3. AUTOMATIC LINKING OF NEW LOCKS TO THE CYCLE
-- =========================================================

CREATE OR REPLACE FUNCTION assign_closure_cycle_to_block()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
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
    RAISE EXCEPTION
      'Для складської точки не знайдено активного циклу закриття';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles
    WHERE id = NEW.closure_cycle_id
      AND storage_point_id = NEW.storage_point_id
      AND reopened_at IS NULL
  ) THEN
    RAISE EXCEPTION
      'Блокування можна створити лише в активному циклі закриття';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_block_cycle_guard
BEFORE INSERT
ON storage_point_closure_blocks
FOR EACH ROW
EXECUTE FUNCTION assign_closure_cycle_to_block();


-- =========================================================
-- 4. HISTORY OF WAREHOUSE LOCATION STATUS CHANGES
-- =========================================================

CREATE TABLE storage_point_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  old_status TEXT NOT NULL,

  new_status TEXT NOT NULL,

  changed_by UUID REFERENCES users(id),

  reason TEXT,

  closure_cycle_id UUID
    REFERENCES storage_point_closure_cycles(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT storage_point_status_history_status_check
    CHECK (
      old_status IN ('active', 'unavailable', 'closed')
      AND new_status IN ('active', 'unavailable', 'closed')
      AND old_status <> new_status
    ),

  CONSTRAINT storage_point_status_history_reason_check
    CHECK (
      reason IS NULL OR LENGTH(reason) <= 2000
    )
);

CREATE INDEX storage_point_status_history_point_idx
  ON storage_point_status_history(storage_point_id, created_at DESC);


-- =========================================================
-- 5. PROHIBITION ON CHANGING STATUS HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_storage_point_status_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію статусів складської точки не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER storage_point_status_history_immutable
BEFORE UPDATE OR DELETE
ON storage_point_status_history
FOR EACH ROW
EXECUTE FUNCTION prevent_storage_point_status_history_mutation();


-- =========================================================
-- 6. PROHIBITION OF RECLOSING WITH UNRESOLVED BLOCKAGES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closure_with_unreleased_blocks()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'closed'
     AND OLD.status <> 'closed' THEN

    IF EXISTS (
      SELECT 1
      FROM storage_point_closure_blocks b
      JOIN storage_point_closure_cycles c
        ON c.id = b.closure_cycle_id
      WHERE b.storage_point_id = NEW.id
        AND c.reopened_at IS NOT NULL
        AND b.initial_quantity > b.released_quantity
    ) THEN
      RAISE EXCEPTION
        'Неможливо повторно закрити точку: залишилися нерозблоковані товари з попереднього циклу';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER storage_point_closure_reopen_guard
BEFORE UPDATE OF status
ON storage_points
FOR EACH ROW
EXECUTE FUNCTION prevent_closure_with_unreleased_blocks();


-- =========================================================
-- 7. AUTHORIZATION FOR REOPENING
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'storage_point_reopen',
  'Повторне відкриття закритої складської точки'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 8. RE-OPENING FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION reopen_storage_point(
  p_storage_point_id UUID,
  p_user_id UUID,
  p_new_status TEXT,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_cycle_id UUID;
  v_old_status TEXT;
BEGIN
  IF p_new_status NOT IN ('active', 'unavailable') THEN
    RAISE EXCEPTION
      'Після закриття точку можна відкрити лише зі статусом active або unavailable';
  END IF;

  IF p_reason IS NULL
     OR LENGTH(TRIM(p_reason)) = 0
     OR LENGTH(p_reason) > 2000 THEN
    RAISE EXCEPTION
      'Необхідно вказати причину повторного відкриття';
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

  IF NOT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp
      ON rp.role_id = ur.role_id
    JOIN permissions p
      ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = 'storage_point_reopen'
  ) THEN
    RAISE EXCEPTION
      'Недостатньо прав для повторного відкриття точки';
  END IF;

  SELECT status
  INTO v_old_status
  FROM storage_points
  WHERE id = p_storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Складську точку не знайдено';
  END IF;

  IF v_old_status <> 'closed' THEN
    RAISE EXCEPTION
      'Повторно відкрити можна лише закриту точку';
  END IF;

  SELECT id
  INTO v_cycle_id
  FROM storage_point_closure_cycles
  WHERE storage_point_id = p_storage_point_id
    AND reopened_at IS NULL
  FOR UPDATE;

  IF v_cycle_id IS NULL THEN
    RAISE EXCEPTION
      'Для точки не знайдено активного циклу закриття';
  END IF;

  UPDATE storage_point_closure_cycles
  SET
    reopened_at = NOW(),
    reopened_by = p_user_id,
    reopening_reason = TRIM(p_reason)
  WHERE id = v_cycle_id;

  UPDATE storage_points
  SET status = p_new_status,
      updated_at = NOW()
  WHERE id = p_storage_point_id;

  INSERT INTO storage_point_status_history (
    storage_point_id,
    old_status,
    new_status,
    changed_by,
    reason,
    closure_cycle_id
  )
  VALUES (
    p_storage_point_id,
    v_old_status,
    p_new_status,
    p_user_id,
    TRIM(p_reason),
    v_cycle_id
  );

  RETURN v_cycle_id;
END;
$$;


-- =========================================================
-- 9. MONITORING OF UNRELEASED RESIDUES AFTER OPENING
-- =========================================================

CREATE OR REPLACE VIEW v_storage_point_closure_remaining AS
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

  (
    b.initial_quantity - b.released_quantity
  ) AS remaining_closure_block_quantity,

  c.closed_at,
  c.reopened_at,

  sp.status AS current_storage_point_status

FROM storage_point_closure_blocks b

JOIN storage_points sp
  ON sp.id = b.storage_point_id

JOIN products p
  ON p.id = b.product_id

JOIN storage_point_closure_cycles c
  ON c.id = b.closure_cycle_id

WHERE b.initial_quantity > b.released_quantity;