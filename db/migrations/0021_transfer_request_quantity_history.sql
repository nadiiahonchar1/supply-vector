-- =========================================================
-- 1. HISTORY OF CHANGES TO THE APPLICATION ITEM QUANTITY
-- =========================================================

CREATE TABLE transfer_request_item_quantity_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_item_id UUID NOT NULL
    REFERENCES transfer_request_items(id),

  old_quantity INTEGER NOT NULL CHECK (old_quantity > 0),

  new_quantity INTEGER NOT NULL CHECK (new_quantity > 0),

  change_reason TEXT NOT NULL
    CHECK (LENGTH(TRIM(change_reason)) BETWEEN 1 AND 2000),

  operation_key UUID NOT NULL UNIQUE,

  changed_by UUID NOT NULL REFERENCES users(id),

  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT quantity_history_values_differ
    CHECK (old_quantity <> new_quantity)
);

CREATE INDEX transfer_request_item_quantity_history_item_idx
  ON transfer_request_item_quantity_history(
    transfer_request_item_id,
    changed_at DESC
  );


-- =========================================================
-- 2. PROTECTING THE JOURNAL FROM EDITING
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_quantity_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історія змін кількості є незмінною';
END;
$$;

CREATE TRIGGER transfer_request_quantity_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_quantity_history
FOR EACH ROW
EXECUTE FUNCTION prevent_quantity_history_mutation();


-- =========================================================
-- 3. VERIFICATION OF THE SUM OF DISTRIBUTIONS ACROSS SOURCES
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id UUID;
  v_requested_quantity INTEGER;
  v_allocated_quantity BIGINT;
BEGIN
  v_item_id := COALESCE(
    NEW.transfer_request_item_id,
    OLD.transfer_request_item_id
  );

  SELECT requested_quantity
  INTO v_requested_quantity
  FROM transfer_request_items
  WHERE id = v_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію заявки не знайдено';
  END IF;

  SELECT COALESCE(SUM(allocated_quantity), 0)
  INTO v_allocated_quantity
  FROM transfer_request_sources
  WHERE transfer_request_item_id = v_item_id
    AND (
      TG_OP <> 'DELETE'
      OR id <> OLD.id
    )
    AND (
      TG_OP <> 'UPDATE'
      OR id <> OLD.id
    );

  IF TG_OP <> 'DELETE' THEN
    v_allocated_quantity :=
      v_allocated_quantity + NEW.allocated_quantity;
  END IF;

  IF v_allocated_quantity > v_requested_quantity THEN
    RAISE EXCEPTION
      'Сума розподілених кількостей перевищує потребу позиції заявки';
  END IF;

  IF v_allocated_quantity < 0 THEN
    RAISE EXCEPTION 'Некоректна сума розподілу';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER transfer_request_source_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source_allocation();


-- =========================================================
-- 4. PROHIBITION ON REDUCING THE REQUIREMENT BELOW THE QUANTITY ALREADY COMMITTED
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
    RAISE EXCEPTION
      'Нова кількість повинна бути більшою за нуль';
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

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Змінювати кількість можна лише в погодженій або виконуваній заявці';
  END IF;

  IF p_new_quantity = v_item.requested_quantity THEN
    RAISE EXCEPTION
      'Нова кількість збігається з поточною';
  END IF;

  SELECT COALESCE(SUM(srm.quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements srm
  JOIN shipment_items si
    ON si.id = srm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(slm.quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements slm
  JOIN shipment_items si
    ON si.id = slm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_resolved
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  v_unresolved_loaded := v_loaded - v_received - v_resolved;

  IF v_unresolved_loaded < 0 THEN
    RAISE EXCEPTION
      'Виявлено некоректний баланс завантаженого товару';
  END IF;

  SELECT COALESCE(
    SUM(
      reserved_quantity
      - consumed_quantity
      - released_quantity
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
      'Нова кількість нижча за суму розподілу між джерелами. Спочатку скоригуйте розподіл';
  END IF;

  UPDATE transfer_request_items
  SET requested_quantity = p_new_quantity
  WHERE id = p_transfer_request_item_id;

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
-- 5. PROHIBITION OF DIRECT QUANTITY CHANGES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_direct_request_quantity_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.requested_quantity IS DISTINCT FROM OLD.requested_quantity THEN
    RAISE EXCEPTION
      'Зміну кількості погодженої заявки потрібно виконувати через спеціальну функцію';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_item_quantity_update_guard
BEFORE UPDATE OF requested_quantity
ON transfer_request_items
FOR EACH ROW
EXECUTE FUNCTION prevent_direct_request_quantity_update();


-- =========================================================
-- 6. STATUS RECALCULATION AFTER A CHANGE IN NEED
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_after_quantity_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM recalculate_transfer_request_status(
    NEW.transfer_request_id
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_recalculate_after_quantity_change
AFTER UPDATE OF requested_quantity
ON transfer_request_items
FOR EACH ROW
WHEN (
  OLD.requested_quantity IS DISTINCT FROM NEW.requested_quantity
)
EXECUTE FUNCTION trigger_recalculate_after_quantity_change();