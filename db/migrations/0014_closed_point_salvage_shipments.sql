-- =========================================================
-- 1. LINKING A SHIPMENT TO A SPECIAL REQUEST
-- =========================================================

ALTER TABLE shipments
ADD COLUMN salvage_request_id UUID
  REFERENCES closed_point_salvage_requests(id);

CREATE INDEX shipments_salvage_request_idx
ON shipments(salvage_request_id)
WHERE salvage_request_id IS NOT NULL;


-- =========================================================
-- 2. RELATIONSHIP BETWEEN THE DISPATCH POSITION AND THE EVACUATION POSITION
-- =========================================================

ALTER TABLE shipment_items
ADD COLUMN salvage_request_item_id UUID
  REFERENCES closed_point_salvage_request_items(id);

CREATE UNIQUE INDEX shipment_items_salvage_item_unique
ON shipment_items(salvage_request_item_id)
WHERE salvage_request_item_id IS NOT NULL;


-- =========================================================
-- 3. VERIFICATION OF THE LINK BETWEEN THE SHIPMENT AND THE SPECIAL REQUEST
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

  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = NEW.salvage_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Спеціальну заявку не знайдено';
  END IF;

  IF v_request.status <> 'approved' THEN
    RAISE EXCEPTION 'Відправлення можна створити лише за погодженою заявкою';
  END IF;

  IF NEW.transfer_request_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Евакуаційне відправлення не може бути прив’язане до звичайної заявки';
  END IF;

  IF NEW.source_storage_point_id <> v_request.source_storage_point_id
     OR NEW.destination_storage_point_id <> v_request.destination_storage_point_id THEN
    RAISE EXCEPTION
      'Джерело або призначення відправлення не відповідає спеціальній заявці';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipments_salvage_validation
BEFORE INSERT OR UPDATE OF
  salvage_request_id,
  transfer_request_id,
  source_storage_point_id,
  destination_storage_point_id
ON shipments
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_shipment();


-- =========================================================
-- 4. VERIFICATION OF EVACUATION SHIPMENT POSITIONS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_shipment_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_salvage_item RECORD;
  v_reservation RECORD;
  v_already_assigned INTEGER;
BEGIN
  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = NEW.shipment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Відправлення не знайдено';
  END IF;

  IF v_shipment.salvage_request_id IS NULL THEN
    IF NEW.salvage_request_item_id IS NOT NULL THEN
      RAISE EXCEPTION
        'Звичайне відправлення не може містити позицію евакуації';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.salvage_request_item_id IS NULL THEN
    RAISE EXCEPTION
      'Для евакуаційного відправлення необхідно вказати позицію спеціальної заявки';
  END IF;

  SELECT *
  INTO v_salvage_item
  FROM closed_point_salvage_request_items
  WHERE id = NEW.salvage_request_item_id
    AND request_id = v_shipment.salvage_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позиція не належить спеціальній заявці цього відправлення';
  END IF;

  IF NEW.transfer_request_source_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Евакуаційне відправлення не використовує звичайне джерело заявки';
  END IF;

  IF NEW.product_id <> v_salvage_item.product_id THEN
    RAISE EXCEPTION 'Товар не відповідає позиції евакуації';
  END IF;

  IF NEW.planned_quantity > v_salvage_item.reserved_quantity THEN
    RAISE EXCEPTION
      'Кількість перевищує зарезервовану кількість евакуації';
  END IF;

  SELECT *
  INTO v_reservation
  FROM inventory_reservations
  WHERE id = v_salvage_item.inventory_reservation_id;

  IF NOT FOUND
     OR v_reservation.salvage_request_item_id <> v_salvage_item.id THEN
    RAISE EXCEPTION 'Резерв евакуації не знайдено';
  END IF;

  SELECT COALESCE(SUM(si.planned_quantity), 0)
  INTO v_already_assigned
  FROM shipment_items si
  WHERE si.salvage_request_item_id = v_salvage_item.id
    AND si.shipment_id <> NEW.shipment_id;

  IF v_already_assigned + NEW.planned_quantity >
     v_salvage_item.reserved_quantity THEN
    RAISE EXCEPTION
      'Загальна кількість відправлень перевищує резерв евакуації';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_items_salvage_validation
BEFORE INSERT OR UPDATE OF
  shipment_id,
  salvage_request_item_id,
  transfer_request_source_id,
  product_id,
  planned_quantity
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_shipment_item();


-- =========================================================
-- 5. CREATING AN EVACUATION SHIPMENT
-- =========================================================

CREATE OR REPLACE FUNCTION create_closed_point_salvage_shipment(
  p_salvage_request_id UUID,
  p_created_by UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_shipment_id UUID;
  v_item RECORD;
  v_shipment_number BIGINT;
BEGIN
  SELECT *
  INTO v_request
  FROM closed_point_salvage_requests
  WHERE id = p_salvage_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Спеціальну заявку не знайдено';
  END IF;

  IF v_request.status <> 'approved' THEN
    RAISE EXCEPTION 'Створити відправлення можна лише за погодженою заявкою';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM shipments
    WHERE salvage_request_id = p_salvage_request_id
  ) THEN
    RAISE EXCEPTION
      'Для цієї спеціальної заявки вже створено відправлення';
  END IF;

  INSERT INTO shipments (
    transfer_request_id,
    salvage_request_id,
    source_storage_point_id,
    destination_storage_point_id,
    status,
    created_by
  )
  VALUES (
    NULL,
    p_salvage_request_id,
    v_request.source_storage_point_id,
    v_request.destination_storage_point_id,
    'pending',
    p_created_by
  )
  RETURNING id, shipment_number
  INTO v_shipment_id, v_shipment_number;

  FOR v_item IN
    SELECT *
    FROM closed_point_salvage_request_items
    WHERE request_id = p_salvage_request_id
    ORDER BY id
  LOOP
    IF v_item.inventory_reservation_id IS NULL
       OR v_item.reserved_quantity <= 0 THEN
      RAISE EXCEPTION
        'Позиція евакуації не має активного резерву';
    END IF;

    INSERT INTO shipment_items (
      shipment_id,
      transfer_request_source_id,
      salvage_request_item_id,
      product_id,
      planned_quantity
    )
    VALUES (
      v_shipment_id,
      NULL,
      v_item.id,
      v_item.product_id,
      v_item.reserved_quantity
    );
  END LOOP;

  INSERT INTO shipment_events (
    shipment_id,
    event_type,
    old_status,
    new_status,
    created_by
  )
  VALUES (
    v_shipment_id,
    'created',
    NULL,
    'pending',
    p_created_by
  );

  RETURN v_shipment_id;
END;
$$;


-- =========================================================
-- 6. PROHIBITION ON CHANGING THE SOURCE AFTER CREATING A SHIPMENT
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_shipment_source_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.salvage_request_id IS NOT NULL
     AND (
       NEW.salvage_request_id IS DISTINCT FROM OLD.salvage_request_id
       OR NEW.source_storage_point_id IS DISTINCT FROM OLD.source_storage_point_id
       OR NEW.destination_storage_point_id IS DISTINCT FROM OLD.destination_storage_point_id
     ) THEN
    RAISE EXCEPTION
      'Джерело та призначення евакуаційного відправлення не можна змінювати';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER prevent_salvage_shipment_source_change
BEFORE UPDATE ON shipments
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_shipment_source_change();