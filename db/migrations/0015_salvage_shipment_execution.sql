-- =========================================================
-- 1. STATUS OF SPECIAL REQUEST EXECUTION
-- =========================================================

ALTER TABLE closed_point_salvage_requests
ADD COLUMN completed_at TIMESTAMPTZ;

ALTER TABLE closed_point_salvage_requests
ADD CONSTRAINT salvage_completed_at_consistency
CHECK (
  (status = 'completed' AND completed_at IS NOT NULL)
  OR
  (status <> 'completed' AND completed_at IS NULL)
);

ALTER TABLE closed_point_salvage_requests
DROP CONSTRAINT closed_point_salvage_requests_status_check;

ALTER TABLE closed_point_salvage_requests
ADD CONSTRAINT closed_point_salvage_requests_status_check
CHECK (
  status IN (
    'pending',
    'approved',
    'rejected',
    'cancelled',
    'completed'
  )
);


-- =========================================================
-- 2. UPDATE TO THE RESERVE CONSUMPTION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION consume_inventory_reservation(
  p_reservation_id UUID,
  p_quantity INTEGER,
  p_shipment_item_id UUID,
  p_user_id UUID,
  p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_reservation RECORD;
  v_inventory RECORD;
  v_shipment_item RECORD;
  v_shipment RECORD;
  v_remaining INTEGER;
  v_movement_id UUID;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість споживання має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT id
  INTO v_movement_id
  FROM inventory_reservation_movements
  WHERE operation_key = p_operation_key;

  IF v_movement_id IS NOT NULL THEN
    RETURN v_movement_id;
  END IF;

  SELECT *
  INTO v_reservation
  FROM inventory_reservations
  WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Резерв не знайдено';
  END IF;

  SELECT
    si.*,
    s.source_storage_point_id,
    s.destination_storage_point_id,
    s.trip_id,
    s.status AS shipment_status,
    s.salvage_request_id
  INTO v_shipment_item
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = p_shipment_item_id
  FOR UPDATE OF si, s;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  IF v_reservation.salvage_request_item_id IS NOT NULL THEN
    IF v_shipment_item.salvage_request_item_id <>
       v_reservation.salvage_request_item_id THEN
      RAISE EXCEPTION
        'Спеціальний резерв не відповідає позиції відправлення';
    END IF;
  ELSE
    IF v_reservation.transfer_request_source_id <>
       v_shipment_item.transfer_request_source_id THEN
      RAISE EXCEPTION
        'Резерв не відповідає джерелу позиції відправлення';
    END IF;
  END IF;

  IF v_shipment_item.shipment_status NOT IN (
    'pending',
    'in_progress'
  ) THEN
    RAISE EXCEPTION
      'Неможливо завантажити товар у поточному статусі відправлення';
  END IF;

  IF v_shipment_item.trip_id IS NULL THEN
    RAISE EXCEPTION 'Відправлення ще не призначене на рейс';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM trips
    WHERE id = v_shipment_item.trip_id
      AND status IN ('ready', 'in_transit')
  ) THEN
    RAISE EXCEPTION 'Рейс не готовий до завантаження';
  END IF;

  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE id = v_reservation.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Залишок товару не знайдено';
  END IF;

  IF v_inventory.storage_point_id <>
     v_shipment_item.source_storage_point_id THEN
    RAISE EXCEPTION 'Резерв належить іншій точці';
  END IF;

  IF v_inventory.product_id <> v_shipment_item.product_id THEN
    RAISE EXCEPTION 'Товар резерву не відповідає відправленню';
  END IF;

  v_remaining :=
    v_reservation.reserved_quantity
    - v_reservation.consumed_quantity
    - v_reservation.released_quantity;

  IF p_quantity > v_remaining THEN
    RAISE EXCEPTION 'Кількість перевищує залишок резерву';
  END IF;

  IF v_inventory.quantity < p_quantity
     OR v_inventory.reserved_quantity < p_quantity THEN
    RAISE EXCEPTION 'Некоректний фізичний або зарезервований залишок';
  END IF;

  UPDATE inventory
  SET
    quantity = quantity - p_quantity,
    reserved_quantity = reserved_quantity - p_quantity
  WHERE id = v_inventory.id;

  UPDATE inventory_reservations
  SET consumed_quantity = consumed_quantity + p_quantity
  WHERE id = p_reservation_id;

  INSERT INTO inventory_movements (
    inventory_id,
    movement_type,
    quantity,
    quantity_before,
    quantity_after,
    reference_type,
    reference_id,
    reason,
    created_by
  )
  VALUES (
    v_inventory.id,
    'shipment_load',
    p_quantity,
    v_inventory.quantity,
    v_inventory.quantity - p_quantity,
    'shipment_item',
    p_shipment_item_id,
    'shipment_loading',
    p_user_id
  );

  INSERT INTO inventory_reservation_movements (
    reservation_id,
    movement_type,
    quantity,
    reference_type,
    reference_id,
    reason,
    created_by,
    operation_key
  )
  VALUES (
    p_reservation_id,
    'consume',
    p_quantity,
    'shipment_item',
    p_shipment_item_id,
    'shipment_loading',
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 3. UPDATE SHIPMENT ITEM LOADING STATUS
-- =========================================================

CREATE OR REPLACE FUNCTION load_shipment_item(
  p_shipment_item_id UUID,
  p_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_reservation_id UUID;
  v_loaded INTEGER;
  v_movement_id UUID;
  v_trip_status TEXT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість завантаження має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT id
  INTO v_movement_id
  FROM shipment_loading_movements
  WHERE operation_key = p_operation_key;

  IF v_movement_id IS NOT NULL THEN
    RETURN v_movement_id;
  END IF;

  SELECT
    si.*,
    s.source_storage_point_id,
    s.destination_storage_point_id,
    s.status AS shipment_status,
    s.trip_id
  INTO v_item
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = p_shipment_item_id
  FOR UPDATE OF si, s;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  IF v_item.shipment_status NOT IN ('pending', 'in_progress') THEN
    RAISE EXCEPTION 'Відправлення не приймає завантаження';
  END IF;

  IF v_item.trip_id IS NULL THEN
    RAISE EXCEPTION 'Відправлення не призначене на рейс';
  END IF;

  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = v_item.trip_id
  FOR UPDATE;

  IF v_trip_status NOT IN ('ready', 'in_transit') THEN
    RAISE EXCEPTION 'Рейс не готовий до завантаження';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements
  WHERE shipment_item_id = p_shipment_item_id;

  IF v_loaded + p_quantity > v_item.planned_quantity THEN
    RAISE EXCEPTION 'Кількість перевищує заплановану';
  END IF;

  IF v_item.salvage_request_item_id IS NOT NULL THEN
    SELECT inventory_reservation_id
    INTO v_reservation_id
    FROM closed_point_salvage_request_items
    WHERE id = v_item.salvage_request_item_id;
  ELSE
    SELECT ir.id
    INTO v_reservation_id
    FROM inventory_reservations ir
    WHERE ir.transfer_request_source_id =
      v_item.transfer_request_source_id;
  END IF;

  IF v_reservation_id IS NULL THEN
    RAISE EXCEPTION 'Резерв для позиції не знайдено';
  END IF;

  PERFORM consume_inventory_reservation(
    v_reservation_id,
    p_quantity,
    p_shipment_item_id,
    p_user_id,
    p_operation_key
  );

  INSERT INTO shipment_loading_movements (
    shipment_item_id,
    quantity,
    operation_key,
    loaded_by,
    comment
  )
  VALUES (
    p_shipment_item_id,
    p_quantity,
    p_operation_key,
    p_user_id,
    p_comment
  )
  RETURNING id INTO v_movement_id;

  IF v_item.shipment_status = 'pending' THEN
    UPDATE shipments
    SET
      status = 'in_progress',
      updated_at = NOW()
    WHERE id = v_item.shipment_id;

    INSERT INTO shipment_events (
      shipment_id,
      event_type,
      old_status,
      new_status,
      created_by
    )
    VALUES (
      v_item.shipment_id,
      'cargo_loaded',
      'pending',
      'in_progress',
      p_user_id
    );
  END IF;

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 4. VERIFICATION OF SPECIAL APPLICATION COMPLETION
-- =========================================================

CREATE OR REPLACE FUNCTION complete_closed_point_salvage_request(
  p_request_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_item RECORD;
  v_received INTEGER;
BEGIN
  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Спеціальну заявку не знайдено';
  END IF;

  IF v_request.status <> 'approved' THEN
    RAISE EXCEPTION 'Заявка не перебуває у статусі approved';
  END IF;

  FOR v_item IN
    SELECT
      sri.id,
      sri.reserved_quantity
    FROM closed_point_salvage_request_items sri
    WHERE sri.request_id = p_request_id
  LOOP
    SELECT COALESCE(SUM(srm.quantity), 0)
    INTO v_received
    FROM shipment_receipt_movements srm
    JOIN shipment_items si
      ON si.id = srm.shipment_item_id
    WHERE si.salvage_request_item_id = v_item.id;

    IF v_received < v_item.reserved_quantity THEN
      RETURN FALSE;
    END IF;
  END LOOP;

  UPDATE closed_point_salvage_requests
  SET
    status = 'completed',
    completed_at = NOW(),
    updated_at = NOW()
  WHERE id = p_request_id;

  INSERT INTO closed_point_salvage_events (
    request_id,
    event_type,
    old_status,
    new_status,
    created_by
  )
  VALUES (
    p_request_id,
    'completed',
    'approved',
    'completed',
    v_request.approved_by
  );

  RETURN TRUE;
END;
$$;


-- =========================================================
-- 5. PROHIBITION ON CHANGING AN AGREED APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_approved_salvage_item_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
  v_status TEXT;
BEGIN
  v_request_id := COALESCE(OLD.request_id, NEW.request_id);

  SELECT status
  INTO v_status
  FROM closed_point_salvage_requests
  WHERE id = v_request_id;

  IF v_status <> 'pending' THEN
    RAISE EXCEPTION
      'Позиції спеціальної заявки після погодження не можна змінювати або видаляти';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER salvage_items_immutable_after_approval
BEFORE UPDATE OR DELETE ON closed_point_salvage_request_items
FOR EACH ROW
EXECUTE FUNCTION prevent_approved_salvage_item_changes();