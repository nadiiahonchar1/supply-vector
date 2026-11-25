-- =========================================================
-- 1. SALVAGE REQUEST APPROVAL LOG
-- =========================================================

CREATE TABLE salvage_request_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_id UUID NOT NULL UNIQUE
    REFERENCES salvage_requests(id),

  approved_by UUID NOT NULL
    REFERENCES users(id),

  approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  comment TEXT,

  CONSTRAINT salvage_approval_comment_check
    CHECK (
      comment IS NULL OR LENGTH(comment) <= 2000
    )
);


-- =========================================================
-- 2. VERIFICATION OF APPROVAL AUTHORITY
-- =========================================================

CREATE OR REPLACE FUNCTION assert_salvage_approval_permission(
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
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
      AND p.code = 'salvage_request_approve'
  ) THEN
    RAISE EXCEPTION
      'Недостатньо прав для погодження спеціальної заявки';
  END IF;
END;
$$;


-- =========================================================
-- 3. ATOMIC AGREEMENT
-- =========================================================

CREATE OR REPLACE FUNCTION approve_salvage_request(
  p_request_id UUID,
  p_approver_id UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_item RECORD;
  v_inventory_id UUID;
  v_reservation_id UUID;
  v_available INTEGER;
  v_released UUID;
BEGIN
  PERFORM assert_salvage_approval_permission(p_approver_id);

  IF p_comment IS NOT NULL AND LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION 'Коментар надто довгий';
  END IF;

  SELECT *
  INTO v_request
  FROM salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Спеціальну заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION
      'Погодити можна лише заявку зі статусом pending';
  END IF;

  IF v_request.created_by = p_approver_id THEN
    RAISE EXCEPTION
      'Автор заявки не може погоджувати власну заявку';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM salvage_request_items
    WHERE salvage_request_id = p_request_id
  ) THEN
    RAISE EXCEPTION
      'Не можна погодити заявку без товарних позицій';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_points
    WHERE id = v_request.source_storage_point_id
      AND status = 'closed'
  ) THEN
    RAISE EXCEPTION
      'Джерело має залишатися закритою точкою';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_points
    WHERE id = v_request.destination_storage_point_id
      AND status IN ('active', 'unavailable')
  ) THEN
    RAISE EXCEPTION
      'Точка призначення недоступна для приймання';
  END IF;

  INSERT INTO salvage_request_approvals (
    salvage_request_id,
    approved_by,
    comment
  )
  VALUES (
    p_request_id,
    p_approver_id,
    p_comment
  );

  FOR v_item IN
    SELECT
      sri.id,
      sri.closure_block_id,
      sri.inspection_id,
      sri.product_id,
      sri.requested_quantity,
      sri.approved_quantity,
      b.storage_point_id,
      b.closure_cycle_id
    FROM salvage_request_items sri
    JOIN storage_point_closure_blocks b
      ON b.id = sri.closure_block_id
    WHERE sri.salvage_request_id = p_request_id
    ORDER BY sri.id
    FOR UPDATE OF sri, b
  LOOP
    IF v_item.approved_quantity IS NOT NULL
       AND v_item.approved_quantity <> v_item.requested_quantity THEN
      RAISE EXCEPTION
        'Затверджена кількість позиції не відповідає запитаній';
    END IF;

    SELECT GREATEST(
      LEAST(
        b.initial_quantity - b.released_quantity,
        i.suitable_quantity
      )
      - COALESCE((
        SELECT SUM(
          m.quantity
        )
        FROM storage_point_closure_block_movements m
        WHERE m.block_id = b.id
          AND m.inspection_id = i.id
          AND m.movement_type = 'release'
      ), 0),
      0
    )
    INTO v_available
    FROM storage_point_closure_blocks b
    JOIN storage_point_closure_inspections i
      ON i.id = v_item.inspection_id
    WHERE b.id = v_item.closure_block_id
    FOR UPDATE OF b;

    IF v_available < v_item.requested_quantity THEN
      RAISE EXCEPTION
        'Недостатньо підтвердженого придатного товару для погодження';
    END IF;

    SELECT id
    INTO v_inventory_id
    FROM inventory
    WHERE storage_point_id = v_item.storage_point_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    IF v_inventory_id IS NULL THEN
      RAISE EXCEPTION
        'Фізичний залишок товару не знайдено';
    END IF;

    PERFORM release_storage_point_closure_block(
      v_item.closure_block_id,
      v_item.requested_quantity,
      p_approver_id,
      v_item.inspection_id
    );

    INSERT INTO inventory_reservations (
      inventory_id,
      reserved_quantity,
      consumed_quantity,
      released_quantity,
      transfer_request_source_id,
      salvage_request_item_id,
      created_at
    )
    VALUES (
      v_inventory_id,
      v_item.requested_quantity,
      0,
      0,
      NULL,
      v_item.id,
      NOW()
    )
    RETURNING id INTO v_reservation_id;

    UPDATE salvage_request_items
    SET approved_quantity = v_item.requested_quantity
    WHERE id = v_item.id;
  END LOOP;

  UPDATE salvage_requests
  SET
    status = 'approved',
    approved_by = p_approver_id,
    approved_at = NOW(),
    updated_at = NOW()
  WHERE id = p_request_id;

  INSERT INTO salvage_request_status_history (
    salvage_request_id,
    old_status,
    new_status,
    changed_by,
    reason
  )
  VALUES (
    p_request_id,
    'pending',
    'approved',
    p_approver_id,
    p_comment
  );

  RETURN p_request_id;
END;
$$;


-- =========================================================
-- 4. PROHIBITION OF DIRECT MODIFICATION OF THE APPROVAL STATUS
-- =========================================================

CREATE OR REPLACE FUNCTION guard_salvage_approval_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status = 'approved' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM salvage_request_approvals a
      WHERE a.salvage_request_id = NEW.id
        AND a.approved_by = NEW.approved_by
    ) THEN
      RAISE EXCEPTION
        'Погодження можливе лише через approve_salvage_request()';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_approval_status_guard
BEFORE UPDATE OF status
ON salvage_requests
FOR EACH ROW
EXECUTE FUNCTION guard_salvage_approval_status();


-- =========================================================
-- 5. REVIEW OF APPROVAL STATUS AND RESERVES
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_request_reservations AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status,
  r.source_storage_point_id,
  r.destination_storage_point_id,

  sri.id AS salvage_request_item_id,
  sri.product_id,
  sri.requested_quantity,
  sri.approved_quantity,

  ir.id AS inventory_reservation_id,
  ir.reserved_quantity,
  ir.consumed_quantity,
  ir.released_quantity,

  (
    ir.reserved_quantity
    - ir.consumed_quantity
    - ir.released_quantity
  ) AS remaining_reserved_quantity

FROM salvage_requests r

JOIN salvage_request_items sri
  ON sri.salvage_request_id = r.id

LEFT JOIN inventory_reservations ir
  ON ir.salvage_request_item_id = sri.id;