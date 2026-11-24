-- =========================================================
-- 1. AUXILIARY CONFIRMATION VERIFICATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION require_storage_point_confirmation(
  p_storage_point_id UUID,
  p_operation_type TEXT,
  p_operation_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_storage_point_operation(
    p_storage_point_id,
    p_operation_type,
    p_operation_id
  );
END;
$$;


-- =========================================================
-- 2. GOODS RECEIPT UPDATE
-- =========================================================

CREATE OR REPLACE FUNCTION receive_shipment_item(
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
  v_employee_id UUID;
  v_received INTEGER;
  v_loaded INTEGER;
  v_resolved INTEGER;
  v_inventory_id UUID;
  v_inventory RECORD;
  v_movement_id UUID;
  v_existing_movement_id UUID;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість приймання має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT id
  INTO v_existing_movement_id
  FROM shipment_receipt_movements
  WHERE operation_key = p_operation_key;

  IF v_existing_movement_id IS NOT NULL THEN
    RETURN v_existing_movement_id;
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

  IF v_item.shipment_status NOT IN (
    'in_progress',
    'partially_delivered'
  ) THEN
    RAISE EXCEPTION
      'Відправлення не перебуває у статусі, що дозволяє приймання';
  END IF;

  SELECT e.id
  INTO v_employee_id
  FROM employees e
  JOIN users u ON u.id = e.user_id
  JOIN storage_point_responsibles spr
    ON spr.employee_id = e.id
  WHERE u.id = p_user_id
    AND u.is_active = TRUE
    AND u.deleted_at IS NULL
    AND e.is_active = TRUE
    AND spr.storage_point_id = v_item.destination_storage_point_id
    AND spr.valid_from <= NOW()
    AND (spr.valid_until IS NULL OR spr.valid_until > NOW())
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION
      'Приймання може виконати лише активна відповідальна особа точки призначення';
  END IF;

  PERFORM require_storage_point_confirmation(
    v_item.destination_storage_point_id,
    'shipment_receive',
    p_operation_key
  );

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements
  WHERE shipment_item_id = p_shipment_item_id;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements
  WHERE shipment_item_id = p_shipment_item_id;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_resolved
  FROM shipment_cargo_movements
  WHERE shipment_item_id = p_shipment_item_id;

  IF v_loaded - v_received - v_resolved < p_quantity THEN
    RAISE EXCEPTION
      'Кількість приймання перевищує невирішений завантажений товар';
  END IF;

  PERFORM 1
  FROM storage_points
  WHERE id = v_item.destination_storage_point_id
    AND status <> 'closed'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точка призначення закрита';
  END IF;

  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE storage_point_id = v_item.destination_storage_point_id
    AND product_id = v_item.product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO inventory (
      storage_point_id,
      product_id,
      quantity,
      reserved_quantity,
      blocked_quantity
    )
    VALUES (
      v_item.destination_storage_point_id,
      v_item.product_id,
      0,
      0,
      0
    )
    RETURNING * INTO v_inventory;
  END IF;

  UPDATE inventory
  SET quantity = quantity + p_quantity
  WHERE id = v_inventory.id;

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
    'shipment_receive',
    p_quantity,
    v_inventory.quantity,
    v_inventory.quantity + p_quantity,
    'shipment_item',
    p_shipment_item_id,
    'shipment_receiving',
    p_user_id
  );

  INSERT INTO shipment_receipt_movements (
    shipment_item_id,
    quantity,
    operation_key,
    received_by,
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

  INSERT INTO shipment_events (
    shipment_id,
    event_type,
    old_status,
    new_status,
    created_by,
    comment
  )
  VALUES (
    v_item.shipment_id,
    'cargo_received',
    v_item.shipment_status,
    v_item.shipment_status,
    p_user_id,
    p_comment
  );

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 3. PRODUCT RETURN UPDATE
-- =========================================================

CREATE OR REPLACE FUNCTION resolve_shipment_cargo(
  p_shipment_item_id UUID,
  p_movement_type TEXT,
  p_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason TEXT,
  p_return_storage_point_id UUID DEFAULT NULL,
  p_from_user_id UUID DEFAULT NULL,
  p_to_user_id UUID DEFAULT NULL,
  p_accounting_act_number TEXT DEFAULT NULL,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_movement_id UUID;
  v_existing_movement_id UUID;
  v_loaded INTEGER;
  v_received INTEGER;
  v_resolved INTEGER;
  v_remaining INTEGER;
  v_inventory RECORD;
  v_trip_id UUID;
BEGIN
  IF p_movement_type IS NULL
     OR p_movement_type NOT IN (
       'return',
       'loss',
       'writeoff',
       'responsibility_transfer'
     ) THEN
    RAISE EXCEPTION 'Невідомий тип руху товару';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість повинна бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину';
  END IF;

  SELECT id
  INTO v_existing_movement_id
  FROM shipment_cargo_movements
  WHERE operation_key = p_operation_key;

  IF v_existing_movement_id IS NOT NULL THEN
    RETURN v_existing_movement_id;
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

  IF v_item.shipment_status IN ('cancelled', 'delivered') THEN
    RAISE EXCEPTION
      'Неможливо змінити долю товару у завершеному відправленні';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements
  WHERE shipment_item_id = p_shipment_item_id;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements
  WHERE shipment_item_id = p_shipment_item_id;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_resolved
  FROM shipment_cargo_movements
  WHERE shipment_item_id = p_shipment_item_id;

  v_remaining := v_loaded - v_received - v_resolved;

  IF p_quantity > v_remaining THEN
    RAISE EXCEPTION
      'Кількість перевищує невирішений залишок вантажу';
  END IF;

  IF p_movement_type = 'return' THEN
    IF p_return_storage_point_id IS NULL THEN
      RAISE EXCEPTION 'Для повернення необхідно вказати точку';
    END IF;

    PERFORM require_storage_point_confirmation(
      p_return_storage_point_id,
      'shipment_return',
      p_operation_key
    );

    PERFORM 1
    FROM storage_points
    WHERE id = p_return_storage_point_id
      AND status <> 'closed'
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Точка повернення закрита';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE storage_point_id = p_return_storage_point_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
      INSERT INTO inventory (
        storage_point_id,
        product_id,
        quantity,
        reserved_quantity,
        blocked_quantity
      )
      VALUES (
        p_return_storage_point_id,
        v_item.product_id,
        0,
        0,
        0
      )
      RETURNING * INTO v_inventory;
    END IF;

    UPDATE inventory
    SET quantity = quantity + p_quantity
    WHERE id = v_inventory.id;

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
      'shipment_return',
      p_quantity,
      v_inventory.quantity,
      v_inventory.quantity + p_quantity,
      'shipment_item',
      p_shipment_item_id,
      p_reason,
      p_user_id
    );
  END IF;

  IF p_movement_type = 'writeoff'
     AND NULLIF(TRIM(p_accounting_act_number), '') IS NULL THEN
    RAISE EXCEPTION
      'Для списання необхідно вказати номер бухгалтерського акта';
  END IF;

  IF p_movement_type = 'responsibility_transfer' THEN
    IF p_from_user_id IS NULL OR p_to_user_id IS NULL
       OR p_from_user_id = p_to_user_id THEN
      RAISE EXCEPTION
        'Для передачі відповідальності потрібні два різні користувачі';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM users
      WHERE id = p_from_user_id
        AND is_active = TRUE
        AND deleted_at IS NULL
    ) OR NOT EXISTS (
      SELECT 1 FROM users
      WHERE id = p_to_user_id
        AND is_active = TRUE
        AND deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION
        'Обидва користувачі повинні мати активні облікові записи';
    END IF;
  END IF;

  INSERT INTO shipment_cargo_movements (
    shipment_item_id,
    movement_type,
    quantity,
    operation_key,
    return_storage_point_id,
    from_user_id,
    to_user_id,
    reason,
    comment,
    accounting_act_number,
    created_by
  )
  VALUES (
    p_shipment_item_id,
    p_movement_type,
    p_quantity,
    p_operation_key,
    p_return_storage_point_id,
    p_from_user_id,
    p_to_user_id,
    p_reason,
    p_comment,
    p_accounting_act_number,
    p_user_id
  )
  RETURNING id INTO v_movement_id;

  IF p_movement_type = 'responsibility_transfer' THEN
    INSERT INTO trip_responsibility_transfers (
      trip_id,
      shipment_item_id,
      quantity,
      from_user_id,
      to_user_id,
      reason,
      created_by
    )
    VALUES (
      v_item.trip_id,
      p_shipment_item_id,
      p_quantity,
      p_from_user_id,
      p_to_user_id,
      p_reason,
      p_user_id
    );
  END IF;

  INSERT INTO shipment_events (
    shipment_id,
    event_type,
    old_status,
    new_status,
    created_by,
    comment
  )
  VALUES (
    v_item.shipment_id,
    p_movement_type,
    v_item.shipment_status,
    v_item.shipment_status,
    p_user_id,
    p_comment
  );

  RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 4. PROHIBITION OF STANDARD RESERVATION OF A CLOSED POINT
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closed_point_inventory_reservation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT sp.status
  INTO v_status
  FROM inventory i
  JOIN storage_points sp ON sp.id = i.storage_point_id
  WHERE i.id = NEW.inventory_id;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION
      'Звичайне резервування із закритої точки заборонене';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_reservation_closed_point_guard
BEFORE INSERT OR UPDATE OF inventory_id
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION prevent_closed_point_inventory_reservation();


-- =========================================================
-- 5. PROHIBITION OF CHANGING PHYSICAL BALANCE AT A CLOSED POINT
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_closed_point_inventory_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status
  INTO v_status
  FROM storage_points
  WHERE id = OLD.storage_point_id;

  IF v_status = 'closed'
     AND (
       NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.reserved_quantity IS DISTINCT FROM OLD.reserved_quantity
       OR NEW.blocked_quantity IS DISTINCT FROM OLD.blocked_quantity
     ) THEN
    RAISE EXCEPTION
      'Зміна залишків закритої точки заборонена звичайними операціями';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER closed_point_inventory_update_guard
BEFORE UPDATE ON inventory
FOR EACH ROW
EXECUTE FUNCTION prevent_closed_point_inventory_update();