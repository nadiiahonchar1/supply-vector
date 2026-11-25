-- =========================================================
-- 1. SINGLE CHECK OF CARGO BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_item_cargo_capacity(
  p_shipment_item_id UUID,
  p_new_quantity NUMERIC,
  p_operation_type TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_loaded NUMERIC;
  v_received NUMERIC;
  v_resolved NUMERIC;
  v_transferred NUMERIC;
  v_available NUMERIC;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість операції повинна бути більшою за нуль';
  END IF;

  SELECT
    COALESCE((
      SELECT SUM(quantity)
      FROM shipment_loading_movements
      WHERE shipment_item_id = p_shipment_item_id
    ), 0),

    COALESCE((
      SELECT SUM(quantity)
      FROM shipment_receipt_movements
      WHERE shipment_item_id = p_shipment_item_id
    ), 0),

    COALESCE((
      SELECT SUM(quantity)
      FROM shipment_cargo_movements
      WHERE shipment_item_id = p_shipment_item_id
        AND movement_type IN ('return', 'loss', 'writeoff')
    ), 0),

    COALESCE((
      SELECT SUM(quantity)
      FROM shipment_cargo_movements
      WHERE shipment_item_id = p_shipment_item_id
        AND movement_type = 'responsibility_transfer'
    ), 0)

  INTO
    v_loaded,
    v_received,
    v_resolved,
    v_transferred;

  IF p_operation_type = 'receipt' THEN
    v_available := v_loaded - v_received - v_resolved;

  ELSIF p_operation_type = 'responsibility_transfer' THEN
    v_available :=
      v_loaded
      - v_received
      - v_resolved
      - v_transferred;

  ELSIF p_operation_type IN ('return', 'loss', 'writeoff') THEN
    v_available :=
      v_loaded
      - v_received
      - v_resolved
      - v_transferred;

  ELSE
    RAISE EXCEPTION
      'Невідомий тип операції з вантажем';
  END IF;

  IF p_new_quantity > v_available THEN
    RAISE EXCEPTION
      'Операція перевищує доступний залишок вантажу. Доступно: %, запитано: %',
      GREATEST(v_available, 0),
      p_new_quantity;
  END IF;
END;
$$;


-- =========================================================
-- 2. PROTECTION OF THE RECEIVING LOGBOOK
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_receipt_capacity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM 1
  FROM shipment_items
  WHERE id = NEW.shipment_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позицію відправлення не знайдено';
  END IF;

  PERFORM assert_shipment_item_cargo_capacity(
    NEW.shipment_item_id,
    NEW.quantity,
    'receipt'
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_receipt_capacity_guard
BEFORE INSERT
ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_receipt_capacity();


-- =========================================================
-- 3. PROTECTION OF THE LOG OF RETURNS, LOSSES, AND WRITE-OFFS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_cargo_movement_capacity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM 1
  FROM shipment_items
  WHERE id = NEW.shipment_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позицію відправлення не знайдено';
  END IF;

  PERFORM assert_shipment_item_cargo_capacity(
    NEW.shipment_item_id,
    NEW.quantity,
    NEW.movement_type
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_cargo_movement_capacity_guard
BEFORE INSERT
ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_cargo_movement_capacity();


-- =========================================================
-- 4. PROTECTION AGAINST QUANTITY CHANGES IN JOURNALS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_cargo_movement_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Фізичні операції з вантажем не можна змінювати або видаляти. Для виправлення необхідно зареєструвати окрему компенсувальну операцію';
END;
$$;

CREATE TRIGGER shipment_loading_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_cargo_movement_mutation();

CREATE TRIGGER shipment_receipt_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_cargo_movement_mutation();

CREATE TRIGGER shipment_cargo_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_cargo_movement_mutation();


-- =========================================================
-- 5. CHECKING THE SHIPMENT AFTER LOADING
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_loading_quantity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_planned NUMERIC;
  v_already_loaded NUMERIC;
BEGIN
  SELECT planned_quantity
  INTO v_planned
  FROM shipment_items
  WHERE id = NEW.shipment_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позицію відправлення не знайдено';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_already_loaded
  FROM shipment_loading_movements
  WHERE shipment_item_id = NEW.shipment_item_id;

  IF v_already_loaded + NEW.quantity > v_planned THEN
    RAISE EXCEPTION
      'Неможливо завантажити більше запланованої кількості. Заплановано: %, уже завантажено: %, нова операція: %',
      v_planned,
      v_already_loaded,
      NEW.quantity;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_loading_quantity_guard
BEFORE INSERT
ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_loading_quantity();


-- =========================================================
-- 6. PROTECTION AGAINST CHANGES TO ALREADY REGISTERED ADOPTIONS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_shipment_item_quantity_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.shipment_id IS DISTINCT FROM OLD.shipment_id
     OR NEW.transfer_request_source_id
        IS DISTINCT FROM OLD.transfer_request_source_id
     OR NEW.salvage_request_item_id
        IS DISTINCT FROM OLD.salvage_request_item_id
     OR NEW.product_id IS DISTINCT FROM OLD.product_id
     OR NEW.planned_quantity IS DISTINCT FROM OLD.planned_quantity THEN

    IF EXISTS (
      SELECT 1
      FROM shipment_loading_movements
      WHERE shipment_item_id = OLD.id
    )
    OR EXISTS (
      SELECT 1
      FROM shipment_receipt_movements
      WHERE shipment_item_id = OLD.id
    )
    OR EXISTS (
      SELECT 1
      FROM shipment_cargo_movements
      WHERE shipment_item_id = OLD.id
    ) THEN
      RAISE EXCEPTION
        'Позицію відправлення з фізичними операціями не можна змінювати';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_item_physical_history_guard
BEFORE UPDATE
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION prevent_shipment_item_quantity_change();