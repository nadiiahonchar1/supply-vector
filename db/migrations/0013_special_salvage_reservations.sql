-- =========================================================
-- 1. EXPANSION OF THE RESERVE MODEL
-- =========================================================

ALTER TABLE inventory_reservations
  ALTER COLUMN transfer_request_source_id DROP NOT NULL;

ALTER TABLE inventory_reservations
  ADD COLUMN salvage_request_item_id UUID
    REFERENCES closed_point_salvage_request_items(id);

ALTER TABLE inventory_reservations
  ADD CONSTRAINT inventory_reservation_single_source_check
  CHECK (
    (
      transfer_request_source_id IS NOT NULL
      AND salvage_request_item_id IS NULL
    )
    OR
    (
      transfer_request_source_id IS NULL
      AND salvage_request_item_id IS NOT NULL
    )
  );

CREATE UNIQUE INDEX inventory_reservations_salvage_item_unique
ON inventory_reservations(salvage_request_item_id)
WHERE salvage_request_item_id IS NOT NULL;


-- =========================================================
-- 2. SPECIAL RESERVATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION reserve_closed_point_salvage_inventory(
  p_salvage_item_id UUID,
  p_quantity INTEGER,
  p_user_id UUID,
  p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_request RECORD;
  v_inventory RECORD;
  v_reservation RECORD;
  v_reservation_id UUID;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість резервування має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT
    sri.*,
    sr.source_storage_point_id,
    sr.destination_storage_point_id,
    sr.status AS request_status
  INTO v_item
  FROM closed_point_salvage_request_items sri
  JOIN closed_point_salvage_requests sr
    ON sr.id = sri.request_id
  WHERE sri.id = p_salvage_item_id
  FOR UPDATE OF sri;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію спеціальної заявки не знайдено';
  END IF;

  IF v_item.request_status <> 'approved' THEN
    RAISE EXCEPTION 'Спеціальна заявка ще не погоджена';
  END IF;

  IF p_quantity <> v_item.quantity THEN
    RAISE EXCEPTION
      'Для цієї операції необхідно зарезервувати всю погоджену кількість';
  END IF;

  SELECT id
  INTO v_reservation_id
  FROM inventory_reservations
  WHERE salvage_request_item_id = p_salvage_item_id;

  IF v_reservation_id IS NOT NULL THEN
    RETURN v_reservation_id;
  END IF;

  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE storage_point_id = v_item.source_storage_point_id
    AND product_id = v_item.product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Залишок товару на джерелі не знайдено';
  END IF;

  IF v_inventory.quantity
     - v_inventory.reserved_quantity
     - v_inventory.blocked_quantity < p_quantity THEN
    RAISE EXCEPTION 'Недостатньо доступного товару для резервування';
  END IF;

  INSERT INTO inventory_reservations (
    inventory_id,
    transfer_request_source_id,
    salvage_request_item_id,
    reserved_quantity,
    consumed_quantity,
    released_quantity,
    created_by
  )
  VALUES (
    v_inventory.id,
    NULL,
    p_salvage_item_id,
    p_quantity,
    0,
    0,
    p_user_id
  )
  RETURNING id INTO v_reservation_id;

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
    'closed_point_salvage',
    p_salvage_item_id,
    'approved_closed_point_salvage',
    p_user_id,
    p_operation_key
  );

  UPDATE closed_point_salvage_request_items
  SET
    reserved_quantity = p_quantity,
    inventory_reservation_id = v_reservation_id
  WHERE id = p_salvage_item_id;

  RETURN v_reservation_id;
END;
$$;


-- =========================================================
-- 3. CORRECTION OF THE APPROVAL OF A SPECIAL APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION approve_closed_point_salvage_request(
  p_request_id UUID,
  p_approver_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_item RECORD;
  v_inventory RECORD;
  v_reservation_id UUID;
  v_available_suitable INTEGER;
  v_operation_key UUID;
  v_has_permission BOOLEAN;
BEGIN
  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'Заявка вже опрацьована';
  END IF;

  IF v_request.created_by = p_approver_id THEN
    RAISE EXCEPTION 'Автор не може погодити власну заявку';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_approver_id
      AND is_active = TRUE
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Обліковий запис погоджувача неактивний';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE ur.user_id = p_approver_id
      AND p.code = 'closed_point_salvage_approve'
  )
  INTO v_has_permission;

  IF NOT v_has_permission THEN
    RAISE EXCEPTION
      'Недостатньо прав для погодження спеціальної заявки';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM closed_point_salvage_request_items
    WHERE request_id = p_request_id
  ) THEN
    RAISE EXCEPTION 'У заявці немає товарів';
  END IF;

  PERFORM 1
  FROM storage_points
  WHERE id = v_request.source_storage_point_id
    AND status = 'closed'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Джерело більше не має статусу closed';
  END IF;

  PERFORM 1
  FROM storage_points
  WHERE id = v_request.destination_storage_point_id
    AND status <> 'closed'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Точка призначення закрита або не знайдена';
  END IF;

  FOR v_item IN
    SELECT *
    FROM closed_point_salvage_request_items
    WHERE request_id = p_request_id
    ORDER BY id
    FOR UPDATE
  LOOP
    PERFORM 1
    FROM storage_point_closure_blocks
    WHERE id = v_item.closure_block_id
    FOR UPDATE;

    PERFORM 1
    FROM storage_point_closure_inspections
    WHERE id = v_item.closure_inspection_id
    FOR UPDATE;

    SELECT
      ci.suitable_quantity
      - COALESCE((
          SELECT SUM(m.quantity)
          FROM storage_point_closure_block_movements m
          WHERE m.inspection_id = ci.id
            AND m.movement_type = 'release'
        ), 0)
    INTO v_available_suitable
    FROM storage_point_closure_inspections ci
    WHERE ci.id = v_item.closure_inspection_id;

    IF v_available_suitable < v_item.quantity THEN
      RAISE EXCEPTION
        'Недостатньо придатного товару за результатами інвентаризації';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE storage_point_id = v_request.source_storage_point_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Залишок товару на джерелі не знайдено';
    END IF;

    IF v_inventory.quantity
       - v_inventory.reserved_quantity
       - v_inventory.blocked_quantity < v_item.quantity THEN
      RAISE EXCEPTION
        'Недостатньо доступного товару. Незалежні блокування не знімаються автоматично';
    END IF;

    PERFORM release_storage_point_closure_block(
      v_item.closure_block_id,
      v_item.quantity,
      v_item.closure_inspection_id,
      p_approver_id,
      'approved_closed_point_salvage'
    );

    v_operation_key := gen_random_uuid();

    v_reservation_id := reserve_closed_point_salvage_inventory(
      v_item.id,
      v_item.quantity,
      p_approver_id,
      v_operation_key
    );
  END LOOP;

  UPDATE closed_point_salvage_requests
  SET
    status = 'approved',
    approved_by = p_approver_id,
    approved_at = NOW(),
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
    'approved',
    'pending',
    'approved',
    p_approver_id
  );

  RETURN p_request_id;
END;
$$;


-- =========================================================
-- 4. REJECTION OF A SPECIAL APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION reject_closed_point_salvage_request(
  p_request_id UUID,
  p_user_id UUID,
  p_rejection_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_has_permission BOOLEAN;
BEGIN
  IF NULLIF(TRIM(p_rejection_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину відхилення';
  END IF;

  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'Відхилити можна лише заявку зі статусом pending';
  END IF;

  IF v_request.created_by = p_user_id THEN
    RAISE EXCEPTION 'Автор не може відхилити власну заявку';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = 'closed_point_salvage_approve'
  )
  INTO v_has_permission;

  IF NOT v_has_permission THEN
    RAISE EXCEPTION 'Недостатньо прав для відхилення заявки';
  END IF;

  UPDATE closed_point_salvage_requests
  SET
    status = 'rejected',
    approved_by = p_user_id,
    approved_at = NOW(),
    rejection_reason = p_rejection_reason,
    updated_at = NOW()
  WHERE id = p_request_id;

  INSERT INTO closed_point_salvage_events (
    request_id,
    event_type,
    old_status,
    new_status,
    comment,
    created_by
  )
  VALUES (
    p_request_id,
    'rejected',
    'pending',
    'rejected',
    p_rejection_reason,
    p_user_id
  );

  RETURN p_request_id;
END;
$$;