-- =========================================================
-- 1. PERMITS FOR A SPECIAL PROCESS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES
  (
    'closed_point_salvage_create',
    'Create closed point salvage requests'
  ),
  (
    'closed_point_salvage_approve',
    'Approve closed point salvage requests'
  )
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. SPECIAL REQUESTS
-- =========================================================

CREATE TABLE closed_point_salvage_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  request_number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,

  source_storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  destination_storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (
      status IN (
        'pending',
        'approved',
        'rejected',
        'cancelled'
      )
    ),

  reason TEXT NOT NULL,

  created_by UUID NOT NULL
    REFERENCES users(id),

  approved_by UUID
    REFERENCES users(id),

  approved_at TIMESTAMPTZ,

  rejection_reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_source_destination_different
    CHECK (
      source_storage_point_id <> destination_storage_point_id
    ),

  CONSTRAINT salvage_approval_not_author
    CHECK (
      approved_by IS NULL
      OR approved_by <> created_by
    ),

  CONSTRAINT salvage_rejection_reason_required
    CHECK (
      status <> 'rejected'
      OR NULLIF(TRIM(rejection_reason), '') IS NOT NULL
    )
);

CREATE INDEX closed_point_salvage_status_idx
ON closed_point_salvage_requests(status);

CREATE INDEX closed_point_salvage_source_idx
ON closed_point_salvage_requests(source_storage_point_id);


-- =========================================================
-- 3. APPLICATION ITEMS
-- =========================================================

CREATE TABLE closed_point_salvage_request_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  request_id UUID NOT NULL
    REFERENCES closed_point_salvage_requests(id),

  closure_block_id UUID NOT NULL
    REFERENCES storage_point_closure_blocks(id),

  closure_inspection_id UUID NOT NULL
    REFERENCES storage_point_closure_inspections(id),

  product_id UUID NOT NULL
    REFERENCES products(id),

  quantity INTEGER NOT NULL
    CHECK (quantity > 0),

  reserved_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (reserved_quantity >= 0),

  inventory_reservation_id UUID
    REFERENCES inventory_reservations(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_item_reserved_not_exceed_quantity
    CHECK (reserved_quantity <= quantity),

  CONSTRAINT salvage_item_reservation_consistency
    CHECK (
      (reserved_quantity = 0 AND inventory_reservation_id IS NULL)
      OR
      (reserved_quantity > 0 AND inventory_reservation_id IS NOT NULL)
    ),

  CONSTRAINT salvage_item_unique_product
    UNIQUE (request_id, product_id)
);


-- =========================================================
-- 4. HISTORY OF EVENTS
-- =========================================================

CREATE TABLE closed_point_salvage_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  request_id UUID NOT NULL
    REFERENCES closed_point_salvage_requests(id),

  event_type TEXT NOT NULL
    CHECK (
      event_type IN (
        'created',
        'approved',
        'rejected',
        'cancelled'
      )
    ),

  old_status TEXT,
  new_status TEXT NOT NULL,

  comment TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX closed_point_salvage_events_request_idx
ON closed_point_salvage_events(request_id, created_at);


CREATE TRIGGER closed_point_salvage_events_immutable
BEFORE UPDATE OR DELETE ON closed_point_salvage_events
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 5. VERIFICATION OF REQUEST CREATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_closed_point_salvage_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_block RECORD;
  v_inspection RECORD;
  v_reserved_from_inspection INTEGER;
  v_released_from_inspection INTEGER;
BEGIN
  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = NEW.request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку на переміщення не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'Додавати товари можна лише до заявки зі статусом pending';
  END IF;

  SELECT *
  INTO v_block
  FROM storage_point_closure_blocks
  WHERE id = NEW.closure_block_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування закритої точки не знайдено';
  END IF;

  IF v_block.storage_point_id <> v_request.source_storage_point_id
     OR v_block.product_id <> NEW.product_id THEN
    RAISE EXCEPTION
      'Товар або точка не відповідають заявці';
  END IF;

  SELECT *
  INTO v_inspection
  FROM storage_point_closure_inspections
  WHERE id = NEW.closure_inspection_id
    AND closure_block_id = NEW.closure_block_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Результат інвентаризації не знайдено';
  END IF;

  SELECT
    COALESCE(SUM(sri.quantity), 0)
  INTO v_reserved_from_inspection
  FROM closed_point_salvage_request_items sri
  JOIN closed_point_salvage_requests sr
    ON sr.id = sri.request_id
  WHERE sri.closure_inspection_id = NEW.closure_inspection_id
    AND sr.status = 'approved';

  SELECT
    COALESCE(SUM(quantity), 0)
  INTO v_released_from_inspection
  FROM storage_point_closure_block_movements
  WHERE inspection_id = NEW.closure_inspection_id
    AND movement_type = 'release';

  IF v_reserved_from_inspection + v_released_from_inspection
     + NEW.quantity > v_inspection.suitable_quantity THEN
    RAISE EXCEPTION
      'Кількість перевищує придатний залишок за результатами інвентаризації';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER closed_point_salvage_item_validation
BEFORE INSERT ON closed_point_salvage_request_items
FOR EACH ROW
EXECUTE FUNCTION validate_closed_point_salvage_item();


-- =========================================================
-- 6. CREATING A REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION create_closed_point_salvage_request(
  p_source_storage_point_id UUID,
  p_destination_storage_point_id UUID,
  p_reason TEXT,
  p_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
  v_source_status TEXT;
  v_destination_status TEXT;
BEGIN
  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину переміщення';
  END IF;

  SELECT status
  INTO v_source_status
  FROM storage_points
  WHERE id = p_source_storage_point_id;

  IF NOT FOUND OR v_source_status <> 'closed' THEN
    RAISE EXCEPTION 'Джерело повинно мати статус closed';
  END IF;

  SELECT status
  INTO v_destination_status
  FROM storage_points
  WHERE id = p_destination_storage_point_id;

  IF NOT FOUND OR v_destination_status = 'closed' THEN
    RAISE EXCEPTION
      'Точка призначення не знайдена або закрита';
  END IF;

  INSERT INTO closed_point_salvage_requests (
    source_storage_point_id,
    destination_storage_point_id,
    reason,
    created_by
  )
  VALUES (
    p_source_storage_point_id,
    p_destination_storage_point_id,
    p_reason,
    p_user_id
  )
  RETURNING id INTO v_request_id;

  INSERT INTO closed_point_salvage_events (
    request_id,
    event_type,
    new_status,
    created_by
  )
  VALUES (
    v_request_id,
    'created',
    'pending',
    p_user_id
  );

  RETURN v_request_id;
END;
$$;


-- =========================================================
-- 7. CREATING A REQUEST — ADDING AN ITEM TO THE REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION add_closed_point_salvage_item(
  p_request_id UUID,
  p_closure_block_id UUID,
  p_inspection_id UUID,
  p_product_id UUID,
  p_quantity INTEGER
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id UUID;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість повинна бути більшою за нуль';
  END IF;

  INSERT INTO closed_point_salvage_request_items (
    request_id,
    closure_block_id,
    closure_inspection_id,
    product_id,
    quantity
  )
  VALUES (
    p_request_id,
    p_closure_block_id,
    p_inspection_id,
    p_product_id,
    p_quantity
  )
  RETURNING id INTO v_item_id;

  RETURN v_item_id;
END;
$$;


-- =========================================================
-- 8. CONSENSUS AND ATOMIC RESERVATION
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
  v_operation_key UUID;
  v_available_suitable INTEGER;
  v_released_from_inspection INTEGER;
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

  IF NOT EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = p_approver_id
      AND r.code IN ('superadmin', 'admin')
  ) THEN
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
        'Недостатньо придатного товару для погодження заявки';
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
        'Недостатньо фізично доступного товару. Незалежні блокування не знімаються автоматично';
    END IF;

    PERFORM release_storage_point_closure_block(
      v_item.closure_block_id,
      v_item.quantity,
      v_item.closure_inspection_id,
      p_approver_id,
      'approved_closed_point_salvage'
    );

    v_operation_key := gen_random_uuid();

    v_reservation_id := reserve_inventory(
      (
        SELECT trs.id
        FROM transfer_request_sources trs
        JOIN transfer_request_items tri
          ON tri.id = trs.transfer_request_item_id
        WHERE FALSE
        LIMIT 1
      ),
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