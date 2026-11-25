-- =========================================================
-- 1. PERMITS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES
  (
    'salvage_request_create',
    'Створення заявок на вилучення товару із закритої точки'
  ),
  (
    'salvage_request_approve',
    'Погодження заявок на вилучення товару із закритої точки'
  ),
  (
    'salvage_request_view',
    'Перегляд заявок на вилучення товару із закритої точки'
  )
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. MAIN APPLICATIONS TABLE
-- =========================================================

CREATE TABLE salvage_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  request_number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,

  source_storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  destination_storage_point_id UUID NOT NULL
    REFERENCES storage_points(id),

  status TEXT NOT NULL DEFAULT 'pending',

  reason TEXT NOT NULL,

  created_by UUID NOT NULL
    REFERENCES users(id),

  approved_by UUID
    REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  approved_at TIMESTAMPTZ,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_request_different_points_check
    CHECK (
      source_storage_point_id <> destination_storage_point_id
    ),

  CONSTRAINT salvage_request_status_check
    CHECK (
      status IN (
        'pending',
        'approved',
        'rejected',
        'in_progress',
        'fulfilled',
        'cancelled'
      )
    ),

  CONSTRAINT salvage_request_reason_check
    CHECK (
      LENGTH(TRIM(reason)) > 0
      AND LENGTH(reason) <= 2000
    ),

  CONSTRAINT salvage_request_approval_check
    CHECK (
      (
        status IN ('approved', 'in_progress', 'fulfilled')
        AND approved_by IS NOT NULL
        AND approved_at IS NOT NULL
      )
      OR
      (
        status IN ('pending', 'rejected', 'cancelled')
        AND approved_by IS NULL
        AND approved_at IS NULL
      )
    )
);

CREATE INDEX salvage_requests_source_idx
  ON salvage_requests(source_storage_point_id, created_at DESC);

CREATE INDEX salvage_requests_destination_idx
  ON salvage_requests(destination_storage_point_id, created_at DESC);

CREATE INDEX salvage_requests_status_idx
  ON salvage_requests(status, created_at DESC);


-- =========================================================
-- 3. APPLICATION POSITIONS
-- =========================================================

CREATE TABLE salvage_request_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_id UUID NOT NULL
    REFERENCES salvage_requests(id),

  closure_block_id UUID NOT NULL
    REFERENCES storage_point_closure_blocks(id),

  inspection_id UUID NOT NULL
    REFERENCES storage_point_closure_inspections(id),

  product_id UUID NOT NULL
    REFERENCES products(id),

  requested_quantity INTEGER NOT NULL,

  approved_quantity INTEGER,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_request_item_quantity_check
    CHECK (requested_quantity > 0),

  CONSTRAINT salvage_request_item_approved_quantity_check
    CHECK (
      approved_quantity IS NULL
      OR (
        approved_quantity > 0
        AND approved_quantity <= requested_quantity
      )
    ),

  CONSTRAINT salvage_request_item_unique_block
    UNIQUE (salvage_request_id, closure_block_id)
);

CREATE INDEX salvage_request_items_request_idx
  ON salvage_request_items(salvage_request_id);

CREATE INDEX salvage_request_items_block_idx
  ON salvage_request_items(closure_block_id);


-- =========================================================
-- 4. APPLICATION STATUS CHANGES LOG
-- =========================================================

CREATE TABLE salvage_request_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_id UUID NOT NULL
    REFERENCES salvage_requests(id),

  old_status TEXT,

  new_status TEXT NOT NULL,

  changed_by UUID NOT NULL
    REFERENCES users(id),

  reason TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_status_history_new_check
    CHECK (
      new_status IN (
        'pending',
        'approved',
        'rejected',
        'in_progress',
        'fulfilled',
        'cancelled'
      )
    )
);

CREATE INDEX salvage_request_status_history_idx
  ON salvage_request_status_history(
    salvage_request_id,
    created_at DESC
  );


-- =========================================================
-- 5. VERIFICATION OF RIGHTS AND STATUS WHEN CREATING POSITIONS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_request_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_block RECORD;
  v_inspection RECORD;
BEGIN
  SELECT
    r.id,
    r.source_storage_point_id,
    r.destination_storage_point_id,
    r.status,
    r.created_by
  INTO v_request
  FROM salvage_requests r
  WHERE r.id = NEW.salvage_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку на вилучення не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION
      'Позиції можна додавати лише до заявки зі статусом pending';
  END IF;

  SELECT
    b.id,
    b.storage_point_id,
    b.product_id,
    b.closure_cycle_id,
    b.initial_quantity,
    b.released_quantity
  INTO v_block
  FROM storage_point_closure_blocks b
  WHERE b.id = NEW.closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Блокування товару не знайдено';
  END IF;

  IF v_block.storage_point_id <> v_request.source_storage_point_id
     OR v_block.product_id <> NEW.product_id THEN
    RAISE EXCEPTION
      'Товар або джерело не відповідає заявці';
  END IF;

  SELECT
    i.id,
    i.block_id,
    i.closure_cycle_id,
    i.suitable_quantity
  INTO v_inspection
  FROM storage_point_closure_inspections i
  WHERE i.id = NEW.inspection_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Інвентаризацію не знайдено';
  END IF;

  IF v_inspection.block_id <> NEW.closure_block_id
     OR v_inspection.closure_cycle_id <> v_block.closure_cycle_id THEN
    RAISE EXCEPTION
      'Інвентаризація не відповідає блокуванню';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_point_closure_cycles c
    WHERE c.id = v_block.closure_cycle_id
      AND c.reopened_at IS NULL
  ) THEN
    RAISE EXCEPTION
      'Спеціальне вилучення можливе лише під час закритого циклу точки';
  END IF;

  IF NEW.requested_quantity > v_inspection.suitable_quantity THEN
    RAISE EXCEPTION
      'Запитана кількість перевищує придатну за результатами інвентаризації';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_request_item_guard
BEFORE INSERT OR UPDATE
ON salvage_request_items
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_request_item();


-- =========================================================
-- 6. PROHIBITION ON EDITING ITEMS AFTER APPROVAL
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_approved_salvage_item_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
  v_status TEXT;
BEGIN
  v_request_id := CASE
    WHEN TG_OP = 'DELETE' THEN OLD.salvage_request_id
    ELSE NEW.salvage_request_id
  END;

  SELECT status
  INTO v_status
  FROM salvage_requests
  WHERE id = v_request_id;

  IF v_status <> 'pending' THEN
    RAISE EXCEPTION
      'Позиції погодженої або завершеної заявки не можна змінювати';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_request_items_immutable_after_approval
BEFORE UPDATE OR DELETE
ON salvage_request_items
FOR EACH ROW
EXECUTE FUNCTION prevent_approved_salvage_item_mutation();


-- =========================================================
-- 7. PROHIBITION ON DELETING APPROVED APPLICATIONS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_request_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'pending' THEN
    RAISE EXCEPTION
      'Погоджені та завершені заявки не можна видаляти';
  END IF;

  RETURN OLD;
END;
$$;

CREATE TRIGGER salvage_requests_delete_guard
BEFORE DELETE
ON salvage_requests
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_request_deletion();


-- =========================================================
-- 8. CHECKING AVAILABLE USABLE QUANTITY
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_available_quantity AS
SELECT
  b.id AS closure_block_id,
  b.closure_cycle_id,
  b.storage_point_id,
  b.product_id,

  b.initial_quantity - b.released_quantity
    AS remaining_closure_block_quantity,

  COALESCE(inspections.suitable_quantity, 0)
    AS inspected_suitable_quantity,

  COALESCE(requests.requested_quantity, 0)
    AS pending_or_approved_quantity,

  GREATEST(
    LEAST(
      b.initial_quantity - b.released_quantity,
      COALESCE(inspections.suitable_quantity, 0)
    )
    - COALESCE(requests.requested_quantity, 0),
    0
  ) AS available_for_salvage

FROM storage_point_closure_blocks b

LEFT JOIN LATERAL (
  SELECT
    SUM(i.suitable_quantity) AS suitable_quantity
  FROM storage_point_closure_inspections i
  WHERE i.block_id = b.id
) inspections ON TRUE

LEFT JOIN LATERAL (
  SELECT
    SUM(
      CASE
        WHEN r.status IN ('pending', 'approved', 'in_progress')
          THEN sri.requested_quantity
        ELSE 0
      END
    ) AS requested_quantity
  FROM salvage_request_items sri
  JOIN salvage_requests r
    ON r.id = sri.salvage_request_id
  WHERE sri.closure_block_id = b.id
) requests ON TRUE;