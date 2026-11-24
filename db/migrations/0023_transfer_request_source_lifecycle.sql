-- =========================================================
-- 1. SOURCE CREATION AND DELETION LOG
-- =========================================================

CREATE TABLE transfer_request_source_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_source_id UUID NOT NULL,

  transfer_request_item_id UUID NOT NULL
    REFERENCES transfer_request_items(id),

  event_type TEXT NOT NULL
    CHECK (event_type IN ('created', 'deleted')),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  allocated_quantity INTEGER NOT NULL
    CHECK (allocated_quantity > 0),

  reason TEXT,

  created_by UUID NOT NULL REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX transfer_request_source_events_item_idx
  ON transfer_request_source_events(
    transfer_request_item_id,
    created_at DESC
  );


-- =========================================================
-- 2. JOURNAL PROTECTION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_source_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історія джерел заявки є незмінною';
END;
$$;

CREATE TRIGGER transfer_request_source_events_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_source_events
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_source_event_mutation();


-- =========================================================
-- 3. VERIFICATION OF THE POSSIBILITY OF USING A POINT
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source_point()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_item RECORD;
  v_point RECORD;
BEGIN
  SELECT *
  INTO v_item
  FROM transfer_request_items
  WHERE id = NEW.transfer_request_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію заявки не знайдено';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_item.transfer_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Не можна змінювати джерела заявки в поточному статусі';
  END IF;

  IF NEW.storage_point_id = v_request.destination_storage_point_id THEN
    RAISE EXCEPTION
      'Точка призначення не може бути джерелом власної заявки';
  END IF;

  SELECT *
  INTO v_point
  FROM storage_points
  WHERE id = NEW.storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_point.status = 'closed' THEN
    RAISE EXCEPTION
      'Закрита точка не може бути звичайним джерелом заявки';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_source_point_guard
BEFORE INSERT OR UPDATE OF storage_point_id, transfer_request_item_id
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_point();


-- =========================================================
-- 4. CONFIRMATION CHECK UNAVAILABLE
-- =========================================================


CREATE OR REPLACE FUNCTION assert_source_allocation_confirmation(
  p_storage_point_id UUID,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = p_storage_point_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Закрита точка недоступна для операції';
  END IF;

  IF v_status = 'unavailable' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM storage_point_operation_confirmations
      WHERE storage_point_id = p_storage_point_id
        AND operation_type = 'transfer_request_source'
        AND operation_id = p_operation_key
    ) THEN
      RAISE EXCEPTION
        'Для недоступної точки потрібне підтвердження відповідальної особи';
    END IF;
  END IF;
END;
$$;


-- =========================================================
-- 5. CREATING AN APPLICATION SOURCE
-- =========================================================

CREATE OR REPLACE FUNCTION add_transfer_request_source(
  p_transfer_request_item_id UUID,
  p_storage_point_id UUID,
  p_allocated_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_request RECORD;
  v_source_id UUID;
  v_existing_id UUID;
BEGIN
  IF p_allocated_quantity IS NULL OR p_allocated_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість розподілу повинна бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_source_events
  WHERE transfer_request_source_id = p_operation_key
    AND event_type = 'created';

  IF v_existing_id IS NOT NULL THEN
    RETURN p_operation_key;
  END IF;

  SELECT *
  INTO v_item
  FROM transfer_request_items
  WHERE id = p_transfer_request_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію заявки не знайдено';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_item.transfer_request_id
  FOR UPDATE;

  IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Додавати джерела можна лише до активної заявки';
  END IF;

  PERFORM assert_source_allocation_confirmation(
    p_storage_point_id,
    p_operation_key
  );

  IF EXISTS (
    SELECT 1
    FROM transfer_request_sources
    WHERE transfer_request_item_id = p_transfer_request_item_id
      AND storage_point_id = p_storage_point_id
  ) THEN
    RAISE EXCEPTION
      'Це джерело вже додане до позиції заявки';
  END IF;

  INSERT INTO transfer_request_sources (
    transfer_request_item_id,
    storage_point_id,
    allocated_quantity,
    created_by
  )
  VALUES (
    p_transfer_request_item_id,
    p_storage_point_id,
    p_allocated_quantity,
    p_user_id
  )
  RETURNING id INTO v_source_id;

  INSERT INTO transfer_request_source_events (
    transfer_request_source_id,
    transfer_request_item_id,
    event_type,
    storage_point_id,
    allocated_quantity,
    reason,
    created_by
  )
  VALUES (
    v_source_id,
    p_transfer_request_item_id,
    'created',
    p_storage_point_id,
    p_allocated_quantity,
    p_reason,
    p_user_id
  );

  RETURN v_source_id;
END;
$$;


-- =========================================================
-- 6. REMOVING THE APPLICATION SOURCE
-- =========================================================

CREATE OR REPLACE FUNCTION delete_transfer_request_source(
  p_source_id UUID,
  p_user_id UUID,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_source RECORD;
  v_item RECORD;
  v_request RECORD;
BEGIN
  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину видалення';
  END IF;

  SELECT *
  INTO v_source
  FROM transfer_request_sources
  WHERE id = p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Джерело заявки не знайдено';
  END IF;

  SELECT *
  INTO v_item
  FROM transfer_request_items
  WHERE id = v_source.transfer_request_item_id
  FOR UPDATE;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_item.transfer_request_id
  FOR UPDATE;

  IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Видаляти джерела можна лише з активної заявки';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM inventory_reservations
    WHERE transfer_request_source_id = p_source_id
  ) THEN
    RAISE EXCEPTION
      'Джерело має історію резервування. Видалення заборонене';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM shipment_items
    WHERE transfer_request_source_id = p_source_id
  ) THEN
    RAISE EXCEPTION
      'Джерело вже використовувалося у відправленні';
  END IF;

  INSERT INTO transfer_request_source_events (
    transfer_request_source_id,
    transfer_request_item_id,
    event_type,
    storage_point_id,
    allocated_quantity,
    reason,
    created_by
  )
  VALUES (
    v_source.id,
    v_source.transfer_request_item_id,
    'deleted',
    v_source.storage_point_id,
    v_source.allocated_quantity,
    TRIM(p_reason),
    p_user_id
  );

  DELETE FROM transfer_request_sources
  WHERE id = p_source_id;
END;
$$;


-- =========================================================
-- 7. PROHIBITION OF DIRECT REMOVAL OF SOURCES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_direct_transfer_source_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting(
    'app.allow_transfer_source_delete',
    TRUE
  ) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION
      'Видалення джерела потрібно виконувати через спеціальну функцію';
  END IF;

  RETURN OLD;
END;
$$;

CREATE TRIGGER transfer_request_source_delete_guard
BEFORE DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION prevent_direct_transfer_source_delete();


-- =========================================================
-- 8. AUTHORIZATION FOR CONTROLLED REMOVAL
-- =========================================================

CREATE OR REPLACE FUNCTION delete_transfer_request_source(
  p_source_id UUID,
  p_user_id UUID,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_source RECORD;
  v_item RECORD;
  v_request RECORD;
BEGIN
  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину видалення';
  END IF;

  SELECT *
  INTO v_source
  FROM transfer_request_sources
  WHERE id = p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Джерело заявки не знайдено';
  END IF;

  SELECT *
  INTO v_item
  FROM transfer_request_items
  WHERE id = v_source.transfer_request_item_id
  FOR UPDATE;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_item.transfer_request_id
  FOR UPDATE;

  IF v_request.status NOT IN ('draft', 'approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Видаляти джерела можна лише з активної заявки';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM inventory_reservations
    WHERE transfer_request_source_id = p_source_id
  ) OR EXISTS (
    SELECT 1
    FROM shipment_items
    WHERE transfer_request_source_id = p_source_id
  ) THEN
    RAISE EXCEPTION
      'Джерело має логістичну історію. Видалення заборонене';
  END IF;

  INSERT INTO transfer_request_source_events (
    transfer_request_source_id,
    transfer_request_item_id,
    event_type,
    storage_point_id,
    allocated_quantity,
    reason,
    created_by
  )
  VALUES (
    v_source.id,
    v_source.transfer_request_item_id,
    'deleted',
    v_source.storage_point_id,
    v_source.allocated_quantity,
    TRIM(p_reason),
    p_user_id
  );

  PERFORM set_config(
    'app.allow_transfer_source_delete',
    'on',
    TRUE
  );

  DELETE FROM transfer_request_sources
  WHERE id = p_source_id;

  PERFORM set_config(
    'app.allow_transfer_source_delete',
    'off',
    TRUE
  );
END;
$$;