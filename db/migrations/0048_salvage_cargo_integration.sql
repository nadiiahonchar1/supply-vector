-- =========================================================
-- 1. RELATIONSHIP BETWEEN GENERAL OPERATIONS AND THE SALVAGE POSITION
-- =========================================================

ALTER TABLE shipment_cargo_movements
  ADD COLUMN IF NOT EXISTS salvage_request_item_id UUID
    REFERENCES salvage_request_items(id);

CREATE INDEX IF NOT EXISTS
  shipment_cargo_movements_salvage_item_idx
ON shipment_cargo_movements(salvage_request_item_id)
WHERE salvage_request_item_id IS NOT NULL;


-- =========================================================
-- 2. VERIFICATION OF SALVAGE MOVEMENT ELIGIBILITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_cargo_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment_request_id UUID;
  v_item_request_id UUID;
  v_shipment_item_id UUID;
BEGIN
  SELECT
    s.salvage_request_id
  INTO v_shipment_request_id
  FROM shipments s
  WHERE s.id = NEW.shipment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Відправлення не знайдено';
  END IF;

  IF v_shipment_request_id IS NULL THEN
    IF NEW.salvage_request_item_id IS NOT NULL THEN
      RAISE EXCEPTION
        'Звичайне відправлення не може містити salvage-рух';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.salvage_request_item_id IS NULL THEN
    RAISE EXCEPTION
      'Для salvage-відправлення необхідно вказати позицію спеціальної заявки';
  END IF;

  SELECT sri.salvage_request_id
  INTO v_item_request_id
  FROM salvage_request_items sri
  WHERE sri.id = NEW.salvage_request_item_id;

  IF v_item_request_id IS DISTINCT FROM v_shipment_request_id THEN
    RAISE EXCEPTION
      'Позиція вантажу не належить salvage-заявці відправлення';
  END IF;

  SELECT si.id
  INTO v_shipment_item_id
  FROM shipment_items si
  WHERE si.shipment_id = NEW.shipment_id
    AND si.salvage_request_item_id = NEW.salvage_request_item_id
  LIMIT 1;

  IF v_shipment_item_id IS NULL THEN
    RAISE EXCEPTION
      'Для цієї позиції немає товару у відправленні';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_cargo_movement_validation
BEFORE INSERT
ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_cargo_movement();


-- =========================================================
-- 3. LOAD CONTROL
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_cargo_loading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id UUID;
  v_approved_quantity INTEGER;
  v_loaded_quantity INTEGER;
BEGIN
  IF NEW.movement_type <> 'loaded' THEN
    RETURN NEW;
  END IF;

  IF NEW.salvage_request_item_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT approved_quantity
  INTO v_approved_quantity
  FROM salvage_request_items
  WHERE id = NEW.salvage_request_item_id
  FOR UPDATE;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded_quantity
  FROM shipment_cargo_movements
  WHERE salvage_request_item_id = NEW.salvage_request_item_id
    AND movement_type = 'loaded';

  IF v_loaded_quantity + NEW.quantity > v_approved_quantity THEN
    RAISE EXCEPTION
      'Завантаження перевищує погоджену кількість salvage-заявки';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_cargo_loading_guard
BEFORE INSERT
ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_cargo_loading();


-- =========================================================
-- 4. REVIEW OF THE PHYSICAL MOVEMENT OF SALVAGE GOODS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_cargo_movements AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,

  sri.id AS salvage_request_item_id,
  sri.product_id,

  s.id AS shipment_id,
  s.shipment_number,
  s.status AS shipment_status,

  scm.id AS movement_id,
  scm.movement_type,
  scm.quantity,
  scm.created_at,
  scm.created_by

FROM shipment_cargo_movements scm

JOIN shipments s
  ON s.id = scm.shipment_id

JOIN salvage_requests r
  ON r.id = s.salvage_request_id

JOIN salvage_request_items sri
  ON sri.id = scm.salvage_request_item_id;


-- =========================================================
-- 5. SALVAGE CARGO MOVEMENT SUMMARY
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_cargo_summary AS
SELECT
  sri.salvage_request_id,
  sri.id AS salvage_request_item_id,
  sri.product_id,
  sri.approved_quantity,

  COALESCE(
    SUM(scm.quantity) FILTER (
      WHERE scm.movement_type = 'loaded'
    ),
    0
  ) AS loaded_quantity,

  COALESCE(
    SUM(scm.quantity) FILTER (
      WHERE scm.movement_type = 'delivered'
    ),
    0
  ) AS delivered_quantity,

  COALESCE(
    SUM(scm.quantity) FILTER (
      WHERE scm.movement_type = 'returned'
    ),
    0
  ) AS returned_quantity,

  COALESCE(
    SUM(scm.quantity) FILTER (
      WHERE scm.movement_type = 'lost'
    ),
    0
  ) AS lost_quantity,

  COALESCE(
    SUM(scm.quantity) FILTER (
      WHERE scm.movement_type = 'written_off'
    ),
    0
  ) AS written_off_quantity

FROM salvage_request_items sri

LEFT JOIN shipment_cargo_movements scm
  ON scm.salvage_request_item_id = sri.id

GROUP BY
  sri.salvage_request_id,
  sri.id,
  sri.product_id,
  sri.approved_quantity;