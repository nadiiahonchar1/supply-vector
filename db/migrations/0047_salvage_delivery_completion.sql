-- =========================================================
-- 1. SALVAGE POSITION EXECUTION LOG
-- =========================================================

CREATE TABLE salvage_item_execution_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_item_id UUID NOT NULL
    REFERENCES salvage_request_items(id),

  shipment_item_id UUID
    REFERENCES shipment_items(id),

  event_type TEXT NOT NULL,

  quantity INTEGER NOT NULL,

  created_by UUID NOT NULL
    REFERENCES users(id),

  comment TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_execution_event_type_check
    CHECK (
      event_type IN (
        'loaded',
        'received',
        'returned',
        'lost',
        'written_off'
      )
    ),

  CONSTRAINT salvage_execution_quantity_check
    CHECK (quantity > 0),

  CONSTRAINT salvage_execution_comment_check
    CHECK (
      comment IS NULL OR LENGTH(comment) <= 2000
    )
);

CREATE INDEX salvage_execution_events_item_idx
  ON salvage_item_execution_events(
    salvage_request_item_id,
    created_at
  );


-- =========================================================
-- 2. PROTECTION OF THE EXECUTION LOG
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_execution_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Журнал фізичного виконання salvage-заявки незмінний';
END;
$$;

CREATE TRIGGER salvage_execution_events_immutable
BEFORE UPDATE OR DELETE
ON salvage_item_execution_events
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_execution_event_mutation();


-- =========================================================
-- 3. APPLICATION STATUS SYNCHRONIZATION
-- =========================================================

CREATE OR REPLACE FUNCTION refresh_salvage_request_status(
  p_request_id UUID,
  p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_total INTEGER;
  v_resolved INTEGER;
  v_loaded INTEGER;
  v_received INTEGER;
  v_current_status TEXT;
  v_new_status TEXT;
BEGIN
  SELECT status
  INTO v_current_status
  FROM salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Salvage-заявку не знайдено';
  END IF;

  IF v_current_status IN ('cancelled', 'rejected', 'fulfilled') THEN
    RETURN v_current_status;
  END IF;

  SELECT
    COALESCE(SUM(sri.approved_quantity), 0),

    COALESCE(SUM(
      CASE
        WHEN ir.id IS NULL THEN 0
        ELSE
          ir.consumed_quantity
          + ir.released_quantity
      END
    ), 0),

    COALESCE(SUM(ir.consumed_quantity), 0)

  INTO
    v_total,
    v_resolved,
    v_loaded

  FROM salvage_request_items sri

  LEFT JOIN inventory_reservations ir
    ON ir.salvage_request_item_id = sri.id

  WHERE sri.salvage_request_id = p_request_id;

  SELECT COALESCE(
    SUM(e.quantity),
    0
  )
  INTO v_received
  FROM salvage_item_execution_events e
  JOIN salvage_request_items sri
    ON sri.id = e.salvage_request_item_id
  WHERE sri.salvage_request_id = p_request_id
    AND e.event_type = 'received';

  IF v_total > 0 AND v_received >= v_total THEN
    v_new_status := 'fulfilled';

  ELSIF v_loaded > 0 THEN
    v_new_status := 'in_progress';

  ELSE
    v_new_status := 'approved';
  END IF;

  IF v_new_status <> v_current_status THEN
    UPDATE salvage_requests
    SET
      status = v_new_status,
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
      v_current_status,
      v_new_status,
      p_user_id,
      'Автоматичне оновлення за результатами фізичного виконання'
    );
  END IF;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 4. VERIFICATION OF PHYSICAL RECEIPT QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_received_quantity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id UUID;
  v_approved INTEGER;
  v_loaded INTEGER;
  v_received INTEGER;
BEGIN
  IF NEW.event_type <> 'received' THEN
    RETURN NEW;
  END IF;

  SELECT approved_quantity
  INTO v_approved
  FROM salvage_request_items
  WHERE id = NEW.salvage_request_item_id
  FOR UPDATE;

  IF v_approved IS NULL THEN
    RAISE EXCEPTION
      'Позиція не має погодженої кількості';
  END IF;

  SELECT COALESCE(
    SUM(e.quantity),
    0
  )
  INTO v_loaded
  FROM salvage_item_execution_events e
  WHERE e.salvage_request_item_id = NEW.salvage_request_item_id
    AND e.event_type = 'loaded';

  SELECT COALESCE(
    SUM(e.quantity),
    0
  )
  INTO v_received
  FROM salvage_item_execution_events e
  WHERE e.salvage_request_item_id = NEW.salvage_request_item_id
    AND e.event_type = 'received';

  IF v_received + NEW.quantity > v_loaded THEN
    RAISE EXCEPTION
      'Не можна прийняти більше товару, ніж було завантажено';
  END IF;

  IF v_received + NEW.quantity > v_approved THEN
    RAISE EXCEPTION
      'Приймання перевищує погоджену кількість';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_received_quantity_guard
BEFORE INSERT
ON salvage_item_execution_events
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_received_quantity();


-- =========================================================
-- 5. STATUS UPDATE AFTER RECORDING RECEIPT
-- =========================================================

CREATE OR REPLACE FUNCTION after_salvage_execution_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT salvage_request_id
  INTO v_request_id
  FROM salvage_request_items
  WHERE id = NEW.salvage_request_item_id;

  PERFORM refresh_salvage_request_status(
    v_request_id,
    NEW.created_by
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_execution_status_sync
AFTER INSERT
ON salvage_item_execution_events
FOR EACH ROW
EXECUTE FUNCTION after_salvage_execution_event();


-- =========================================================
-- 6. VIEW REQUEST STATUS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_request_delivery_status AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status,

  sri.id AS salvage_request_item_id,
  sri.product_id,
  sri.approved_quantity,

  COALESCE(events.loaded_quantity, 0)
    AS loaded_quantity,

  COALESCE(events.received_quantity, 0)
    AS received_quantity,

  COALESCE(events.returned_quantity, 0)
    AS returned_quantity,

  COALESCE(events.lost_quantity, 0)
    AS lost_quantity,

  COALESCE(events.written_off_quantity, 0)
    AS written_off_quantity,

  GREATEST(
    sri.approved_quantity
    - COALESCE(events.received_quantity, 0)
    - COALESCE(events.returned_quantity, 0)
    - COALESCE(events.lost_quantity, 0)
    - COALESCE(events.written_off_quantity, 0),
    0
  ) AS unresolved_quantity

FROM salvage_requests r

JOIN salvage_request_items sri
  ON sri.salvage_request_id = r.id

LEFT JOIN LATERAL (
  SELECT
    SUM(quantity) FILTER (
      WHERE event_type = 'loaded'
    ) AS loaded_quantity,

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