-- =========================================================
-- 1. DECISION REGARDED THE FUTURE OF THE SALVAGE CARGO
-- =========================================================

CREATE TABLE salvage_cargo_dispositions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_item_id UUID NOT NULL
    REFERENCES salvage_request_items(id),

  shipment_item_id UUID NOT NULL
    REFERENCES shipment_items(id),

  disposition_type TEXT NOT NULL,

  quantity INTEGER NOT NULL,

  destination_storage_point_id UUID
    REFERENCES storage_points(id),

  reason TEXT NOT NULL,

  act_number TEXT,

  responsible_user_id UUID NOT NULL
    REFERENCES users(id),

  created_by UUID NOT NULL
    REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_disposition_type_check
    CHECK (
      disposition_type IN (
        'returned',
        'lost',
        'written_off'
      )
    ),

  CONSTRAINT salvage_disposition_quantity_check
    CHECK (quantity > 0),

  CONSTRAINT salvage_disposition_reason_check
    CHECK (LENGTH(TRIM(reason)) > 0),

  CONSTRAINT salvage_disposition_return_point_check
    CHECK (
      (
        disposition_type = 'returned'
        AND destination_storage_point_id IS NOT NULL
      )
      OR
      (
        disposition_type <> 'returned'
        AND destination_storage_point_id IS NULL
      )
    ),

  CONSTRAINT salvage_disposition_writeoff_act_check
    CHECK (
      disposition_type <> 'written_off'
      OR NULLIF(TRIM(act_number), '') IS NOT NULL
    )
);

CREATE INDEX salvage_dispositions_item_idx
  ON salvage_cargo_dispositions(
    salvage_request_item_id,
    created_at
  );

CREATE INDEX salvage_dispositions_shipment_item_idx
  ON salvage_cargo_dispositions(shipment_item_id);


-- =========================================================
-- 2. VERIFICATION OF CARGO OWNERSHIP
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_cargo_disposition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_salvage_item_id UUID;
  v_request_id UUID;
  v_shipment_request_id UUID;
  v_loaded_quantity INTEGER;
  v_received_quantity INTEGER;
  v_already_disposed INTEGER;
BEGIN
  SELECT
    si.salvage_request_item_id,
    s.salvage_request_id
  INTO
    v_salvage_item_id,
    v_shipment_request_id
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE si.id = NEW.shipment_item_id
  FOR UPDATE OF si;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  IF v_salvage_item_id IS NULL
     OR v_salvage_item_id <> NEW.salvage_request_item_id THEN
    RAISE EXCEPTION
      'Позиція відправлення не відповідає salvage-заявці';
  END IF;

  SELECT salvage_request_id
  INTO v_request_id
  FROM salvage_request_items
  WHERE id = NEW.salvage_request_item_id
  FOR UPDATE;

  IF v_request_id IS DISTINCT FROM v_shipment_request_id THEN
    RAISE EXCEPTION
      'Відправлення та salvage-заявка не відповідають одне одному';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded_quantity
  FROM shipment_cargo_movements
  WHERE shipment_id = (
    SELECT shipment_id
    FROM shipment_items
    WHERE id = NEW.shipment_item_id
  )
    AND movement_type = 'loaded'
    AND shipment_item_id = NEW.shipment_item_id;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_received_quantity
  FROM salvage_item_execution_events
  WHERE shipment_item_id = NEW.shipment_item_id
    AND event_type = 'received';

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_already_disposed
  FROM salvage_cargo_dispositions
  WHERE shipment_item_id = NEW.shipment_item_id
    AND id <> NEW.id;

  IF v_received_quantity + v_already_disposed + NEW.quantity
     > v_loaded_quantity THEN
    RAISE EXCEPTION
      'Кількість рішення перевищує невирішений фізичний вантаж';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_cargo_disposition_validation
BEFORE INSERT OR UPDATE
ON salvage_cargo_dispositions
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_cargo_disposition();


-- =========================================================
-- 3. PROTECTION OF DECISION HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_disposition_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Зареєстроване рішення щодо долі вантажу не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER salvage_dispositions_immutable
BEFORE UPDATE OR DELETE
ON salvage_cargo_dispositions
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_disposition_mutation();


-- =========================================================
-- 4. LINKING DECISIONS TO THE EXECUTION LOG
-- =========================================================

ALTER TABLE salvage_item_execution_events
  ADD COLUMN IF NOT EXISTS disposition_id UUID
    REFERENCES salvage_cargo_dispositions(id);

CREATE INDEX salvage_execution_disposition_idx
  ON salvage_item_execution_events(disposition_id)
  WHERE disposition_id IS NOT NULL;


-- =========================================================
-- 5. VERIFICATION OF THE GROUNDS FOR RETURN, LOSS, OR WRITE-OFF
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_disposition_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_disposition RECORD;
BEGIN
  IF NEW.event_type NOT IN (
    'returned',
    'lost',
    'written_off'
  ) THEN
    IF NEW.disposition_id IS NOT NULL THEN
      RAISE EXCEPTION
        'Для цієї події не потрібне рішення щодо долі вантажу';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.disposition_id IS NULL THEN
    RAISE EXCEPTION
      'Необхідно вказати рішення щодо долі вантажу';
  END IF;

  SELECT *
  INTO v_disposition
  FROM salvage_cargo_dispositions
  WHERE id = NEW.disposition_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Рішення щодо долі вантажу не знайдено';
  END IF;

  IF v_disposition.salvage_request_item_id
     <> NEW.salvage_request_item_id THEN
    RAISE EXCEPTION
      'Рішення належить іншій позиції salvage-заявки';
  END IF;

  IF v_disposition.shipment_item_id
     <> NEW.shipment_item_id THEN
    RAISE EXCEPTION
      'Рішення належить іншій позиції відправлення';
  END IF;

  IF v_disposition.disposition_type <> NEW.event_type THEN
    RAISE EXCEPTION
      'Тип фізичної події не відповідає рішенню';
  END IF;

  IF NEW.quantity <> v_disposition.quantity THEN
    RAISE EXCEPTION
      'Кількість фізичної події не відповідає рішенню';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM salvage_item_execution_events
    WHERE disposition_id = NEW.disposition_id
  ) THEN
    RAISE EXCEPTION
      'Це рішення вже використано для фізичної події';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_disposition_event_guard
BEFORE INSERT
ON salvage_item_execution_events
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_disposition_event();


-- =========================================================
-- 6. REVIEW OF DECISIONS REGARDING THE FATE OF THE CARGO
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_cargo_dispositions AS
SELECT
  d.id AS disposition_id,

  d.salvage_request_item_id,
  sri.salvage_request_id,
  r.request_number,

  d.shipment_item_id,
  s.id AS shipment_id,
  s.shipment_number,

  d.disposition_type,
  d.quantity,

  d.destination_storage_point_id,

  d.reason,
  d.act_number,

  d.responsible_user_id,
  d.created_by,
  d.created_at,

  e.id AS execution_event_id

FROM salvage_cargo_dispositions d

JOIN salvage_request_items sri
  ON sri.id = d.salvage_request_item_id

JOIN salvage_requests r
  ON r.id = sri.salvage_request_id

JOIN shipment_items si
  ON si.id = d.shipment_item_id

JOIN shipments s
  ON s.id = si.shipment_id

LEFT JOIN salvage_item_execution_events e
  ON e.disposition_id = d.id;


-- =========================================================
-- 7. CONTROL OF UNREGISTERED PHYSICAL EVENTS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_disposition_integrity AS
SELECT
  d.id AS disposition_id,
  d.salvage_request_item_id,
  d.shipment_item_id,
  d.disposition_type,
  d.quantity,

  e.id AS execution_event_id,

  CASE
    WHEN e.id IS NULL THEN FALSE
    ELSE TRUE
  END AS physical_event_registered

FROM salvage_cargo_dispositions d

LEFT JOIN salvage_item_execution_events e
  ON e.disposition_id = d.id;