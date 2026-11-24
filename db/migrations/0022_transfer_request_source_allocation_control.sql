-- =========================================================
-- 1. HISTORY OF CHANGES IN DISTRIBUTION BETWEEN SOURCES
-- =========================================================

CREATE TABLE transfer_request_source_allocation_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_source_id UUID NOT NULL
    REFERENCES transfer_request_sources(id),

  old_quantity INTEGER NOT NULL CHECK (old_quantity > 0),

  new_quantity INTEGER NOT NULL CHECK (new_quantity > 0),

  reason TEXT NOT NULL
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000),

  operation_key UUID NOT NULL UNIQUE,

  changed_by UUID NOT NULL REFERENCES users(id),

  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT source_allocation_history_values_differ
    CHECK (old_quantity <> new_quantity)
);

CREATE INDEX source_allocation_history_source_idx
  ON transfer_request_source_allocation_history(
    transfer_request_source_id,
    changed_at DESC
  );


-- =========================================================
-- 2. DEFENDING HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_source_allocation_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історія розподілу між джерелами є незмінною';
END;
$$;

CREATE TRIGGER source_allocation_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_source_allocation_history
FOR EACH ROW
EXECUTE FUNCTION prevent_source_allocation_history_mutation();


-- =========================================================
-- 3. CORRECTION OF THE APPLICATION QUANTITY PROTECTION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_direct_request_quantity_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.requested_quantity IS DISTINCT FROM OLD.requested_quantity
     AND current_setting(
       'app.allow_request_quantity_update',
       TRUE
     ) IS DISTINCT FROM 'on' THEN

    RAISE EXCEPTION
      'Зміну кількості потрібно виконувати через спеціальну функцію';
  END IF;

  RETURN NEW;
END;
$$;


-- =========================================================
-- 4. UPDATED NEED CHANGE FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION change_transfer_request_item_quantity(
  p_transfer_request_item_id UUID,
  p_new_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_request RECORD;

  v_existing_id UUID;
  v_history_id UUID;

  v_received BIGINT := 0;
  v_loaded BIGINT := 0;
  v_resolved BIGINT := 0;
  v_unresolved_loaded BIGINT := 0;

  v_active_reserved BIGINT := 0;
  v_allocated BIGINT := 0;
  v_minimum_quantity BIGINT := 0;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
    RAISE EXCEPTION 'Нова кількість повинна бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину зміни';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_item_quantity_history
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
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

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Змінювати кількість можна лише в погодженій або виконуваній заявці';
  END IF;

  IF p_new_quantity = v_item.requested_quantity THEN
    RAISE EXCEPTION 'Нова кількість збігається з поточною';
  END IF;

  SELECT COALESCE(SUM(srm.quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements srm
  JOIN shipment_items si ON si.id = srm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(slm.quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements slm
  JOIN shipment_items si ON si.id = slm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_resolved
  FROM shipment_cargo_movements scm
  JOIN shipment_items si ON si.id = scm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  v_unresolved_loaded := v_loaded - v_received - v_resolved;

  IF v_unresolved_loaded < 0 THEN
    RAISE EXCEPTION 'Некоректний баланс завантаженого товару';
  END IF;

  SELECT COALESCE(
    SUM(
      ir.reserved_quantity
      - ir.consumed_quantity
      - ir.released_quantity
    ),
    0
  )
  INTO v_active_reserved
  FROM inventory_reservations ir
  JOIN transfer_request_sources trs
    ON trs.id = ir.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(allocated_quantity), 0)
  INTO v_allocated
  FROM transfer_request_sources
  WHERE transfer_request_item_id = p_transfer_request_item_id;

  v_minimum_quantity :=
    v_received
    + v_unresolved_loaded
    + v_active_reserved
    + v_item.cancelled_quantity;

  IF p_new_quantity < v_minimum_quantity THEN
    RAISE EXCEPTION
      'Нова кількість нижча за вже отриману, завантажену, зарезервовану або скасовану кількість';
  END IF;

  IF p_new_quantity < v_allocated THEN
    RAISE EXCEPTION
      'Спочатку скоригуйте розподіл між джерелами';
  END IF;

  PERFORM set_config(
    'app.allow_request_quantity_update',
    'on',
    TRUE
  );

  UPDATE transfer_request_items
  SET requested_quantity = p_new_quantity
  WHERE id = p_transfer_request_item_id;

  PERFORM set_config(
    'app.allow_request_quantity_update',
    'off',
    TRUE
  );

  INSERT INTO transfer_request_item_quantity_history (
    transfer_request_item_id,
    old_quantity,
    new_quantity,
    change_reason,
    operation_key,
    changed_by
  )
  VALUES (
    p_transfer_request_item_id,
    v_item.requested_quantity,
    p_new_quantity,
    TRIM(p_reason),
    p_operation_key,
    p_user_id
  )
  RETURNING id INTO v_history_id;

  RETURN v_history_id;
END;
$$;


-- =========================================================
-- 5. CORRECTION OF THE DISTRIBUTION SUM CHECK
-- =========================================================

DROP TRIGGER IF EXISTS transfer_request_source_allocation_guard
ON transfer_request_sources;

CREATE OR REPLACE FUNCTION validate_transfer_request_source_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id UUID;
  v_requested_quantity INTEGER;
  v_allocated_quantity BIGINT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_item_id := OLD.transfer_request_item_id;
  ELSE
    v_item_id := NEW.transfer_request_item_id;
  END IF;

  SELECT requested_quantity
  INTO v_requested_quantity
  FROM transfer_request_items
  WHERE id = v_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію заявки не знайдено';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_allocated_quantity
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_item_id;

    v_allocated_quantity :=
      v_allocated_quantity + NEW.allocated_quantity;

  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.transfer_request_item_id <>
       OLD.transfer_request_item_id THEN
      RAISE EXCEPTION
        'Переносити джерело між позиціями заявки заборонено';
    END IF;

    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_allocated_quantity
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_item_id
      AND id <> OLD.id;

    v_allocated_quantity :=
      v_allocated_quantity + NEW.allocated_quantity;

  ELSE
    SELECT COALESCE(SUM(allocated_quantity), 0)
    INTO v_allocated_quantity
    FROM transfer_request_sources
    WHERE transfer_request_item_id = v_item_id
      AND id <> OLD.id;
  END IF;

  IF v_allocated_quantity > v_requested_quantity THEN
    RAISE EXCEPTION
      'Сума розподілу перевищує потребу позиції заявки';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER transfer_request_source_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_allocation();


-- =========================================================
-- 6. PROTECTION OF A SOURCE ALREADY INVOLVED IN LOGISTICS
-- =========================================================

CREATE OR REPLACE FUNCTION protect_logistically_used_request_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' OR
     NEW.storage_point_id IS DISTINCT FROM OLD.storage_point_id OR
     NEW.transfer_request_item_id IS DISTINCT FROM OLD.transfer_request_item_id OR
     NEW.allocated_quantity IS DISTINCT FROM OLD.allocated_quantity
  THEN
    IF EXISTS (
      SELECT 1
      FROM inventory_reservations
      WHERE transfer_request_source_id = OLD.id
    ) THEN
      RAISE EXCEPTION
        'Джерело має історію резервування. Змінювати його заборонено';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM shipment_items
      WHERE transfer_request_source_id = OLD.id
    ) THEN
      RAISE EXCEPTION
        'Джерело вже використане у відправленні. Змінювати його заборонено';
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER protect_logistically_used_request_source_guard
BEFORE UPDATE OR DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION protect_logistically_used_request_source();


-- =========================================================
-- 7. CONTROLLED CHANGE IN SOURCE QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION change_transfer_request_source_allocation(
  p_source_id UUID,
  p_new_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_source RECORD;
  v_existing_id UUID;
  v_history_id UUID;
  v_total_other BIGINT;
  v_requested INTEGER;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість розподілу повинна бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину зміни';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_source_allocation_history
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  SELECT *
  INTO v_source
  FROM transfer_request_sources
  WHERE id = p_source_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Джерело заявки не знайдено';
  END IF;

  PERFORM 1
  FROM transfer_request_items
  WHERE id = v_source.transfer_request_item_id
  FOR UPDATE;

  SELECT requested_quantity
  INTO v_requested
  FROM transfer_request_items
  WHERE id = v_source.transfer_request_item_id;

  IF EXISTS (
    SELECT 1
    FROM inventory_reservations
    WHERE transfer_request_source_id = p_source_id
  ) THEN
    RAISE EXCEPTION
      'Джерело вже має резерви. Спочатку потрібно завершити або звільнити їх';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM shipment_items
    WHERE transfer_request_source_id = p_source_id
  ) THEN
    RAISE EXCEPTION
      'Джерело вже використане у відправленні. Зміна заборонена';
  END IF;

  SELECT COALESCE(SUM(allocated_quantity), 0)
  INTO v_total_other
  FROM transfer_request_sources
  WHERE transfer_request_item_id = v_source.transfer_request_item_id
    AND id <> p_source_id;

  IF v_total_other + p_new_quantity > v_requested THEN
    RAISE EXCEPTION
      'Нова кількість перевищує залишок потреби позиції заявки';
  END IF;

  UPDATE transfer_request_sources
  SET allocated_quantity = p_new_quantity
  WHERE id = p_source_id;

  INSERT INTO transfer_request_source_allocation_history (
    transfer_request_source_id,
    old_quantity,
    new_quantity,
    reason,
    operation_key,
    changed_by
  )
  VALUES (
    p_source_id,
    v_source.allocated_quantity,
    p_new_quantity,
    TRIM(p_reason),
    p_operation_key,
    p_user_id
  )
  RETURNING id INTO v_history_id;

  RETURN v_history_id;
END;
$$;