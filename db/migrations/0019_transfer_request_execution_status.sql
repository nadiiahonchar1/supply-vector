-- =========================================================
-- 1. QUANTITY OF PERMANENTLY CANCELLED GOODS
-- =========================================================

ALTER TABLE transfer_request_items
ADD COLUMN IF NOT EXISTS cancelled_quantity INTEGER NOT NULL DEFAULT 0;

ALTER TABLE transfer_request_items
ADD CONSTRAINT transfer_request_items_cancelled_quantity_check
CHECK (
  cancelled_quantity >= 0
  AND cancelled_quantity <= requested_quantity
);


-- =========================================================
-- 2. APPLICATION STATUS RECALCULATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_transfer_request_status(
  p_request_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;

  v_total_requested BIGINT := 0;
  v_total_cancelled BIGINT := 0;
  v_total_received BIGINT := 0;
  v_total_loaded BIGINT := 0;

  v_new_status TEXT;
BEGIN
  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку на переміщення не знайдено';
  END IF;

  IF v_request.status IN ('draft', 'pending') THEN
    RETURN v_request.status;
  END IF;

  IF v_request.status IN (
    'fulfilled',
    'partially_fulfilled',
    'cancelled'
  ) THEN
    RETURN v_request.status;
  END IF;

  SELECT
    COALESCE(SUM(requested_quantity), 0),
    COALESCE(SUM(cancelled_quantity), 0)
  INTO
    v_total_requested,
    v_total_cancelled
  FROM transfer_request_items
  WHERE transfer_request_id = p_request_id;

  IF v_total_requested = 0 THEN
    RAISE EXCEPTION
      'Неможливо визначити виконання заявки без товарних позицій';
  END IF;

  SELECT COALESCE(SUM(srm.quantity), 0)
  INTO v_total_received
  FROM shipment_receipt_movements srm
  JOIN shipment_items si
    ON si.id = srm.shipment_item_id
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE s.transfer_request_id = p_request_id;

  SELECT COALESCE(SUM(slm.quantity), 0)
  INTO v_total_loaded
  FROM shipment_loading_movements slm
  JOIN shipment_items si
    ON si.id = slm.shipment_item_id
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE s.transfer_request_id = p_request_id;

  IF v_total_received + v_total_cancelled > v_total_requested THEN
    RAISE EXCEPTION
      'Отримана та скасована кількість перевищує потребу заявки';
  END IF;

  IF v_total_received = v_total_requested THEN
    v_new_status := 'fulfilled';

  ELSIF v_total_received > 0
    AND v_total_received + v_total_cancelled = v_total_requested THEN
    v_new_status := 'partially_fulfilled';

  ELSIF v_total_received = 0
    AND v_total_cancelled = v_total_requested THEN
    v_new_status := 'cancelled';

  ELSIF v_total_loaded > 0 OR v_total_received > 0 THEN
    v_new_status := 'in_progress';

  ELSE
    v_new_status := 'approved';
  END IF;

  UPDATE transfer_requests
  SET
    status = v_new_status,
    updated_at = NOW()
  WHERE id = p_request_id;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 3. RECALCULATION AFTER RECEIPT OF GOODS
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_transfer_request_after_receipt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT s.transfer_request_id
  INTO v_request_id
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_recalculate_after_receipt
AFTER INSERT ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_transfer_request_after_receipt();


-- =========================================================
-- 4. RECALCULATION AFTER LOADING
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_transfer_request_after_loading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT s.transfer_request_id
  INTO v_request_id
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_recalculate_after_loading
AFTER INSERT ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_transfer_request_after_loading();


-- =========================================================
-- 5. RECALCULATION AFTER CHANGING THE CANCELLED QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_transfer_request_after_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM recalculate_transfer_request_status(
    NEW.transfer_request_id
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_recalculate_after_cancellation
AFTER UPDATE OF cancelled_quantity
ON transfer_request_items
FOR EACH ROW
WHEN (
  OLD.cancelled_quantity IS DISTINCT FROM NEW.cancelled_quantity
)
EXECUTE FUNCTION trigger_recalculate_transfer_request_after_cancellation();