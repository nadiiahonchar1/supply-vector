-- =========================================================
-- 1. UNIVERSAL POINT STATUS CHECK
-- =========================================================

CREATE OR REPLACE FUNCTION assert_storage_point_operation(
  p_storage_point_id UUID,
  p_operation_type TEXT,
  p_operation_id UUID
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

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION
      'Операція заборонена: точка має статус closed';
  END IF;

  IF v_status = 'unavailable' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM storage_point_operation_confirmations
      WHERE storage_point_id = p_storage_point_id
        AND operation_type = p_operation_type
        AND operation_id = p_operation_id
    ) THEN
      RAISE EXCEPTION
        'Для операції потрібне підтвердження відповідальної особи точки зі статусом unavailable';
    END IF;
  END IF;
END;
$$;


-- =========================================================
-- 2. VERIFICATION OF TWO POINTS OF A SINGLE OPERATION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_storage_points_operation(
  p_source_storage_point_id UUID,
  p_destination_storage_point_id UUID,
  p_operation_type TEXT,
  p_operation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_storage_point_operation(
    p_source_storage_point_id,
    p_operation_type,
    p_operation_id
  );

  IF p_destination_storage_point_id IS NOT NULL
     AND p_destination_storage_point_id <>
         p_source_storage_point_id THEN
    PERFORM assert_storage_point_operation(
      p_destination_storage_point_id,
      p_operation_type,
      p_operation_id
    );
  END IF;
END;
$$;


-- =========================================================
-- 3. PROHIBITION OF CONFIRMATION FOR CLOSED POINTS
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
  WHERE id = NEW.storage_point_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точку зберігання не знайдено';
  END IF;

  IF v_status <> 'unavailable' THEN
    RAISE EXCEPTION
      'Підтвердження можливе лише для точки зі статусом unavailable';
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
      'Підтвердити операцію може лише активна відповідальна особа точки';
  END IF;

  RETURN NEW;
END;
$$;


-- =========================================================
-- 4. RESERVING A STANDARD ITEM
-- =========================================================

CREATE OR REPLACE FUNCTION reserve_inventory(
  p_transfer_request_source_id UUID,
  p_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_source RECORD;
  v_request RECORD;
  v_inventory RECORD;
  v_reservation RECORD;
  v_reservation_id UUID;
  v_available INTEGER;
  v_remaining_allocation INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість резервування має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT reservation_id
  INTO v_reservation
  FROM inventory_reservation_movements
  WHERE operation_key = p_operation_key;

  IF v_reservation.reservation_id IS NOT NULL THEN
    RETURN v_reservation.reservation_id;
  END IF;

  SELECT
    trs.*,
    tri.product_id,
    tri.requested_quantity,
    tr.destination_storage_point_id,
    tr.status AS request_status
  INTO v_source
  FROM transfer_request_sources trs
  JOIN transfer_request_items tri
    ON tri.id = trs.transfer_request_item_id
  JOIN transfer_requests tr
    ON tr.id = tri.transfer_request_id
  WHERE trs.id = p_transfer_request_source_id
  FOR UPDATE OF trs;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Джерело заявки не знайдено';
  END IF;

  IF v_source.request_status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Резервувати можна лише товар погодженої або виконуваної заявки';
  END IF;

  IF v_source.storage_point_id = v_source.destination_storage_point_id THEN
    RAISE EXCEPTION 'Джерело не може бути точкою призначення';
  END IF;

  PERFORM assert_storage_point_operation(
    v_source.storage_point_id,
    'inventory_reservation',
    p_operation_key
  );

  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE storage_point_id = v_source.storage_point_id
    AND product_id = v_source.product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Залишок товару на джерелі не знайдено';
  END IF;

  v_available :=
    v_inventory.quantity
    - v_inventory.reserved_quantity
    - v_inventory.blocked_quantity;

  IF v_available < p_quantity THEN
    RAISE EXCEPTION 'Недостатньо доступного товару';
  END IF;

  SELECT COALESCE(SUM(reserved_quantity), 0)
       - COALESCE(SUM(consumed_quantity), 0)
       - COALESCE(SUM(released_quantity), 0)
  INTO v_remaining_allocation
  FROM inventory_reservations
  WHERE transfer_request_source_id = p_transfer_request_source_id;

  IF v_remaining_allocation + p_quantity >
     v_source.allocated_quantity THEN
    RAISE EXCEPTION
      'Кількість резервування перевищує виділену кількість джерела';
  END IF;

  SELECT *
  INTO v_reservation
  FROM inventory_reservations
  WHERE transfer_request_source_id = p_transfer_request_source_id
    AND inventory_id = v_inventory.id
  FOR UPDATE;

  IF FOUND THEN
    UPDATE inventory_reservations
    SET reserved_quantity = reserved_quantity + p_quantity
    WHERE id = v_reservation.id
    RETURNING id INTO v_reservation_id;
  ELSE
    INSERT INTO inventory_reservations (
      inventory_id,
      transfer_request_source_id,
      reserved_quantity,
      consumed_quantity,
      released_quantity,
      created_by
    )
    VALUES (
      v_inventory.id,
      p_transfer_request_source_id,
      p_quantity,
      0,
      0,
      p_user_id
    )
    RETURNING id INTO v_reservation_id;
  END IF;

  UPDATE inventory
  SET reserved_quantity = reserved_quantity + p_quantity
  WHERE id = v_inventory.id;

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
    v_reservation_id,
    'reserve',
    p_quantity,
    'transfer_request_source',
    p_transfer_request_source_id,
    'transfer_request_reservation',
    p_user_id,
    p_operation_key
  );

  RETURN v_reservation_id;
END;
$$;


-- =========================================================
-- 5. CHECKING POINTS DURING LOADING
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_loading_confirmation(
  p_shipment_item_id UUID,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
BEGIN
  SELECT
    si.id,
    s.source_storage_point_id
  INTO v_item
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = p_shipment_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  PERFORM assert_storage_point_operation(
    v_item.source_storage_point_id,
    'shipment_load',
    p_operation_key
  );
END;
$$;


-- =========================================================
-- 6. POINT VERIFICATION UPON RECEIPT
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_receiving_confirmation(
  p_shipment_item_id UUID,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
BEGIN
  SELECT
    si.id,
    s.destination_storage_point_id
  INTO v_item
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = p_shipment_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  PERFORM assert_storage_point_operation(
    v_item.destination_storage_point_id,
    'shipment_receive',
    p_operation_key
  );
END;
$$;


-- =========================================================
-- 7. POINT VERIFICATION UPON PRODUCT RETURN
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_return_confirmation(
  p_return_storage_point_id UUID,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_storage_point_operation(
    p_return_storage_point_id,
    'shipment_return',
    p_operation_key
  );
END;
$$;


-- =========================================================
-- 8. INSPECTION UPON RECEIPT OF GOODS
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_operation_points(
  p_shipment_id UUID,
  p_operation_type TEXT,
  p_operation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
BEGIN
  SELECT
    source_storage_point_id,
    destination_storage_point_id
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Відправлення не знайдено';
  END IF;

  PERFORM assert_storage_points_operation(
    v_shipment.source_storage_point_id,
    v_shipment.destination_storage_point_id,
    p_operation_type,
    p_operation_id
  );
END;
$$;