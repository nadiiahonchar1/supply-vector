-- =========================================================
-- 1. LOG OF LOSSES AND WRITE-OFFS
-- =========================================================

CREATE TABLE salvage_loss_writeoff_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  disposition_id UUID NOT NULL UNIQUE
    REFERENCES salvage_cargo_dispositions(id),

  salvage_request_item_id UUID NOT NULL
    REFERENCES salvage_request_items(id),

  shipment_item_id UUID NOT NULL
    REFERENCES shipment_items(id),

  operation_type TEXT NOT NULL,

  quantity INTEGER NOT NULL,

  reason TEXT NOT NULL,

  act_number TEXT,

  responsible_user_id UUID NOT NULL
    REFERENCES users(id),

  recorded_by UUID NOT NULL
    REFERENCES users(id),

  comment TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_loss_writeoff_type_check
    CHECK (
      operation_type IN ('lost', 'written_off')
    ),

  CONSTRAINT salvage_loss_writeoff_quantity_check
    CHECK (quantity > 0),

  CONSTRAINT salvage_loss_writeoff_reason_check
    CHECK (LENGTH(TRIM(reason)) > 0),

  CONSTRAINT salvage_writeoff_act_check
    CHECK (
      operation_type <> 'written_off'
      OR NULLIF(TRIM(act_number), '') IS NOT NULL
    )
);

CREATE INDEX salvage_loss_writeoff_item_idx
  ON salvage_loss_writeoff_records(
    salvage_request_item_id,
    created_at
  );


-- =========================================================
-- 2. VERIFICATION OF DECISION COMPLIANCE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_loss_writeoff()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_disposition RECORD;
BEGIN
  SELECT
    d.id,
    d.disposition_type,
    d.quantity,
    d.salvage_request_item_id,
    d.shipment_item_id
  INTO v_disposition
  FROM salvage_cargo_dispositions d
  WHERE d.id = NEW.disposition_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Рішення щодо долі вантажу не знайдено';
  END IF;

  IF v_disposition.disposition_type
     <> NEW.operation_type THEN
    RAISE EXCEPTION
      'Тип операції не відповідає рішенню';
  END IF;

  IF v_disposition.quantity <> NEW.quantity THEN
    RAISE EXCEPTION
      'Кількість не відповідає рішенню';
  END IF;

  IF v_disposition.salvage_request_item_id
     <> NEW.salvage_request_item_id THEN
    RAISE EXCEPTION
      'Неправильна позиція salvage-заявки';
  END IF;

  IF v_disposition.shipment_item_id
     <> NEW.shipment_item_id THEN
    RAISE EXCEPTION
      'Неправильна позиція відправлення';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_loss_writeoff_validation
BEFORE INSERT
ON salvage_loss_writeoff_records
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_loss_writeoff();


-- =========================================================
-- 3. DEFENDING HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_loss_writeoff_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Запис про втрату або списання не можна змінювати чи видаляти';
END;
$$;

CREATE TRIGGER salvage_loss_writeoff_immutable
BEFORE UPDATE OR DELETE
ON salvage_loss_writeoff_records
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_loss_writeoff_mutation();


-- =========================================================
-- 4. VERIFICATION OF A PHYSICAL EVENT
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_loss_writeoff_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_record RECORD;
BEGIN
  IF NEW.event_type NOT IN ('lost', 'written_off') THEN
    RETURN NEW;
  END IF;

  IF NEW.disposition_id IS NULL THEN
    RAISE EXCEPTION
      'Необхідне рішення щодо втрати або списання';
  END IF;

  SELECT *
  INTO v_record
  FROM salvage_loss_writeoff_records
  WHERE disposition_id = NEW.disposition_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Запис про втрату або списання не знайдено';
  END IF;

  IF v_record.operation_type <> NEW.event_type THEN
    RAISE EXCEPTION
      'Тип фізичної події не відповідає запису';
  END IF;

  IF v_record.salvage_request_item_id
     <> NEW.salvage_request_item_id THEN
    RAISE EXCEPTION
      'Позиція salvage-заявки не відповідає запису';
  END IF;

  IF v_record.shipment_item_id
     <> NEW.shipment_item_id THEN
    RAISE EXCEPTION
      'Позиція відправлення не відповідає запису';
  END IF;

  IF v_record.quantity <> NEW.quantity THEN
    RAISE EXCEPTION
      'Кількість фізичної події не відповідає запису';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_loss_writeoff_event_guard
BEFORE INSERT
ON salvage_item_execution_events
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_loss_writeoff_event();


-- =========================================================
-- 5. REVIEW OF LOSSES AND WRITE-OFFS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_loss_writeoff_overview AS
SELECT
  rec.id AS record_id,

  rec.salvage_request_item_id,
  sri.salvage_request_id,
  r.request_number,

  rec.shipment_item_id,
  s.id AS shipment_id,
  s.shipment_number,

  rec.operation_type,
  rec.quantity,
  rec.reason,
  rec.act_number,

  rec.responsible_user_id,
  rec.recorded_by,
  rec.created_at,

  e.id AS execution_event_id

FROM salvage_loss_writeoff_records rec

JOIN salvage_request_items sri
  ON sri.id = rec.salvage_request_item_id

JOIN salvage_requests r
  ON r.id = sri.salvage_request_id

JOIN shipment_items si
  ON si.id = rec.shipment_item_id

JOIN shipments s
  ON s.id = si.shipment_id

LEFT JOIN salvage_item_execution_events e
  ON e.disposition_id = rec.disposition_id;


-- =========================================================
-- 6. FINAL CONTROL OVER THE FATE OF SALVAGE GOODS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_item_final_accounting AS
SELECT
  sri.salvage_request_id,
  sri.id AS salvage_request_item_id,
  sri.product_id,
  sri.approved_quantity,

  COALESCE(events.received_quantity, 0)
    AS received_quantity,

  COALESCE(events.returned_quantity, 0)
    AS returned_quantity,

  COALESCE(events.lost_quantity, 0)
    AS lost_quantity,

  COALESCE(events.written_off_quantity, 0)
    AS written_off_quantity,

  COALESCE(events.received_quantity, 0)
  + COALESCE(events.returned_quantity, 0)
  + COALESCE(events.lost_quantity, 0)
  + COALESCE(events.written_off_quantity, 0)
    AS accounted_quantity,

  sri.approved_quantity
  - (
      COALESCE(events.received_quantity, 0)
      + COALESCE(events.returned_quantity, 0)
      + COALESCE(events.lost_quantity, 0)
      + COALESCE(events.written_off_quantity, 0)
    )
    AS unresolved_quantity

FROM salvage_request_items sri

LEFT JOIN LATERAL (
  SELECT
    SUM(quantity) FILTER (
      WHERE event_type = 'received'
    ) AS received_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'returned'
    ) AS returned_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'lost'
    ) AS lost_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'written_off'
    ) AS written_off_quantity

  FROM salvage_item_execution_events
  WHERE salvage_request_item_id = sri.id
) events ON TRUE;