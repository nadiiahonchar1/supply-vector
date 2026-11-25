-- =========================================================
-- 1. AUTHORIZATION TO CREATE SALVAGE SHIPMENTS
-- =========================================================

INSERT INTO permissions (code, name)
VALUES
  (
    'salvage_shipment_create',
    'Створення відправлень за спеціальними заявками'
  ),
  (
    'salvage_shipment_manage',
    'Керування відправленнями за спеціальними заявками'
  )
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. LINKING SHIPMENTS TO SALVAGE CLAIMS
-- =========================================================

ALTER TABLE shipments
  ALTER COLUMN transfer_request_id DROP NOT NULL;

ALTER TABLE shipments
  ADD COLUMN IF NOT EXISTS salvage_request_id UUID
    REFERENCES salvage_requests(id);

ALTER TABLE shipments
  ADD CONSTRAINT shipment_exactly_one_request_source
  CHECK (
    (
      transfer_request_id IS NOT NULL
      AND salvage_request_id IS NULL
    )
    OR
    (
      transfer_request_id IS NULL
      AND salvage_request_id IS NOT NULL
    )
  );

CREATE INDEX shipments_salvage_request_idx
  ON shipments(salvage_request_id)
  WHERE salvage_request_id IS NOT NULL;


-- =========================================================
-- 3. LINKING SHIPMENT ITEMS TO SALVAGE ITEMS
-- =========================================================

ALTER TABLE shipment_items
  ADD COLUMN IF NOT EXISTS salvage_request_item_id UUID
    REFERENCES salvage_request_items(id);

ALTER TABLE shipment_items
  ALTER COLUMN transfer_request_source_id DROP NOT NULL;

ALTER TABLE shipment_items
  ADD CONSTRAINT shipment_item_exactly_one_source
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

CREATE INDEX shipment_items_salvage_request_item_idx
  ON shipment_items(salvage_request_item_id)
  WHERE salvage_request_item_id IS NOT NULL;


-- =========================================================
-- 4. VERIFICATION OF SALVAGE REQUEST SUBMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_shipment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
BEGIN
  IF NEW.salvage_request_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT
    r.id,
    r.status,
    r.source_storage_point_id,
    r.destination_storage_point_id
  INTO v_request
  FROM salvage_requests r
  WHERE r.id = NEW.salvage_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Salvage-заявку не знайдено';
  END IF;

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Створювати відправлення можна лише за погодженою заявкою';
  END IF;

  IF NEW.source_storage_point_id <>
     v_request.source_storage_point_id THEN
    RAISE EXCEPTION
      'Джерело відправлення не відповідає salvage-заявці';
  END IF;

  IF NEW.destination_storage_point_id <>
     v_request.destination_storage_point_id THEN
    RAISE EXCEPTION
      'Призначення відправлення не відповідає salvage-заявці';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_shipment_validation
BEFORE INSERT OR UPDATE OF salvage_request_id,
  source_storage_point_id,
  destination_storage_point_id
ON shipments
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_shipment();


-- =========================================================
-- 5. CHECKING SALVAGE SHIPMENT ITEMS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_shipment_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_request_item RECORD;
  v_reserved INTEGER;
  v_already_planned INTEGER;
BEGIN
  SELECT
    s.id,
    s.salvage_request_id,
    s.source_storage_point_id,
    s.destination_storage_point_id
  INTO v_shipment
  FROM shipments s
  WHERE s.id = NEW.shipment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Відправлення не знайдено';
  END IF;

  IF v_shipment.salvage_request_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT
    sri.id,
    sri.product_id,
    sri.approved_quantity
  INTO v_request_item
  FROM salvage_request_items sri
  WHERE sri.id = NEW.salvage_request_item_id
    AND sri.salvage_request_id = v_shipment.salvage_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позиція не належить відповідній salvage-заявці';
  END IF;

  IF NEW.product_id <> v_request_item.product_id THEN
    RAISE EXCEPTION
      'Товар не відповідає позиції salvage-заявки';
  END IF;

  IF v_request_item.approved_quantity IS NULL THEN
    RAISE EXCEPTION
      'Позиція salvage-заявки ще не погоджена';
  END IF;

  SELECT
    ir.reserved_quantity
    - ir.consumed_quantity
    - ir.released_quantity
  INTO v_reserved
  FROM inventory_reservations ir
  WHERE ir.salvage_request_item_id = v_request_item.id
  FOR UPDATE;

  IF v_reserved IS NULL THEN
    RAISE EXCEPTION
      'Спеціальний резерв не знайдено';
  END IF;

  SELECT COALESCE(
    SUM(si.planned_quantity),
    0
  )
  INTO v_already_planned
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE si.salvage_request_item_id = v_request_item.id
    AND si.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000')
    AND s.status <> 'cancelled';

  IF v_already_planned + NEW.planned_quantity > v_reserved THEN
    RAISE EXCEPTION
      'Сумарна запланована кількість перевищує залишок спеціального резерву';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_shipment_item_validation
BEFORE INSERT OR UPDATE OF shipment_id,
  salvage_request_item_id,
  product_id,
  planned_quantity
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_shipment_item();


-- =========================================================
-- 6. REVIEW OF SHIPMENTS UNDER SALVAGE REQUESTS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_shipment_overview AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status AS request_status,

  s.id AS shipment_id,
  s.shipment_number,
  s.status AS shipment_status,
  s.trip_id,

  s.source_storage_point_id,
  s.destination_storage_point_id,

  COUNT(DISTINCT si.id) AS item_count,

  COALESCE(SUM(si.planned_quantity), 0)
    AS planned_quantity,

  s.created_at

FROM salvage_requests r

LEFT JOIN shipments s
  ON s.salvage_request_id = r.id

LEFT JOIN shipment_items si
  ON si.shipment_id = s.id

GROUP BY
  r.id,
  r.request_number,
  r.status,
  s.id,
  s.shipment_number,
  s.status,
  s.trip_id,
  s.source_storage_point_id,
  s.destination_storage_point_id,
  s.created_at;


-- =========================================================
-- 7. MONITORING THE EXECUTION OF SALVAGE REQUESTS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_request_execution AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status,

  sri.id AS salvage_request_item_id,
  sri.product_id,
  sri.approved_quantity,

  COALESCE(planned.total_planned, 0)
    AS total_planned_quantity,

  COALESCE(loaded.total_loaded, 0)
    AS total_loaded_quantity,

  COALESCE(received.total_received, 0)
    AS total_received_quantity

FROM salvage_requests r

JOIN salvage_request_items sri
  ON sri.salvage_request_id = r.id

LEFT JOIN LATERAL (
  SELECT SUM(si.planned_quantity) AS total_planned
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.salvage_request_item_id = sri.id
    AND s.status <> 'cancelled'
) planned ON TRUE

LEFT JOIN LATERAL (
  SELECT SUM(l.quantity) AS total_loaded
  FROM shipment_loading_items l
  JOIN shipment_items si ON si.id = l.shipment_item_id
  WHERE si.salvage_request_item_id = sri.id
) loaded ON TRUE

LEFT JOIN LATERAL (
  SELECT SUM(rc.quantity) AS total_received
  FROM shipment_receipt_items rc
  JOIN shipment_items si ON si.id = rc.shipment_item_id
  WHERE si.salvage_request_item_id = sri.id
) received ON TRUE;