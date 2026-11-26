-- =========================================================
-- 1. RECALCULATE TRANSFER REQUEST EXECUTION STATUS
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_transfer_request_status(
  p_request_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;

  v_total_requested BIGINT;
  v_total_cancelled BIGINT;
  v_total_received BIGINT;

  v_has_shipments BOOLEAN;
  v_new_status TEXT;
BEGIN
  SELECT
    id,
    status
  INTO v_request
  FROM transfer_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_FOUND';
  END IF;

  IF v_request.status IN (
    'draft',
    'pending',
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
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_HAS_NO_ITEMS';
  END IF;

  SELECT
    COALESCE(SUM(sco.quantity), 0)
  INTO v_total_received
  FROM shipment_cargo_operations sco
  JOIN shipment_items si
    ON si.id = sco.shipment_item_id
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE s.transfer_request_id = p_request_id
    AND sco.operation_type = 'receive';

  IF v_total_received + v_total_cancelled > v_total_requested THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_QUANTITY_EXCEEDED';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM shipments
    WHERE transfer_request_id = p_request_id
  )
  INTO v_has_shipments;

  IF v_total_received = v_total_requested THEN
    v_new_status := 'fulfilled';

  ELSIF v_total_received > 0
    AND v_total_received + v_total_cancelled = v_total_requested THEN
    v_new_status := 'partially_fulfilled';

  ELSIF v_total_received = 0
    AND v_total_cancelled = v_total_requested THEN
    v_new_status := 'cancelled';

  ELSIF v_has_shipments OR v_total_received > 0 THEN
    v_new_status := 'in_progress';

  ELSE
    v_new_status := 'approved';
  END IF;

  UPDATE transfer_requests
  SET
    status = v_new_status,
    completed_at = CASE
      WHEN v_new_status IN ('fulfilled', 'partially_fulfilled')
        THEN COALESCE(completed_at, NOW())
      ELSE completed_at
    END,
    cancelled_at = CASE
      WHEN v_new_status = 'cancelled'
        THEN COALESCE(cancelled_at, NOW())
      ELSE cancelled_at
    END,
    updated_at = NOW()
  WHERE id = p_request_id;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 2. RECALCULATE AFTER CARGO RECEIPT
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_transfer_request_after_cargo_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  IF NEW.operation_type <> 'receive' THEN
    RETURN NEW;
  END IF;

  SELECT s.transfer_request_id
  INTO v_request_id
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_recalculate_after_cargo_receipt
AFTER INSERT ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_transfer_request_after_cargo_operation();


-- =========================================================
-- 3. RECALCULATE AFTER CANCELLING REQUEST QUANTITY
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