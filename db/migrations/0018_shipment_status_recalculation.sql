-- =========================================================
-- 1. NORMALIZE SHIPMENT STATUSES
-- =========================================================

ALTER TABLE shipments
DROP CONSTRAINT IF EXISTS shipments_status_check;

ALTER TABLE shipments
ADD CONSTRAINT shipments_status_check
CHECK (
  status IN (
    'pending',
    'in_transit',
    'completed',
    'cancelled'
  )
);


-- =========================================================
-- 2. RECALCULATE SHIPMENT STATUS
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_shipment_status(
  p_shipment_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_loaded INTEGER;
  v_received INTEGER;
  v_returned INTEGER;
  v_lost INTEGER;
  v_written_off INTEGER;
  v_resolved INTEGER;
  v_unresolved INTEGER;
  v_new_status TEXT;
BEGIN
  SELECT
    id,
    status
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_NOT_FOUND';
  END IF;

  IF v_shipment.status IN ('cancelled', 'completed') THEN
    RETURN v_shipment.status;
  END IF;

  SELECT
    COALESCE(
      SUM(quantity) FILTER (WHERE operation_type = 'load'),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (WHERE operation_type = 'receive'),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (WHERE operation_type = 'return'),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (WHERE operation_type = 'loss'),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (WHERE operation_type = 'writeoff'),
      0
    )
  INTO
    v_loaded,
    v_received,
    v_returned,
    v_lost,
    v_written_off
  FROM shipment_cargo_operations sco
  JOIN shipment_items si
    ON si.id = sco.shipment_item_id
  WHERE si.shipment_id = p_shipment_id;

  v_resolved :=
    v_received
    + v_returned
    + v_lost
    + v_written_off;

  v_unresolved := v_loaded - v_resolved;

  IF v_unresolved < 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_CARGO_BALANCE_INVALID';
  END IF;

  IF v_shipment.status = 'pending' THEN
    v_new_status := 'pending';

  ELSIF v_shipment.status = 'in_transit'
    AND v_loaded > 0
    AND v_unresolved = 0 THEN
    v_new_status := 'completed';

  ELSE
    v_new_status := v_shipment.status;
  END IF;

  IF v_new_status IS DISTINCT FROM v_shipment.status THEN
    UPDATE shipments
    SET
      status = v_new_status,
      updated_at = NOW()
    WHERE id = p_shipment_id;
  END IF;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 3. RECALCULATE AFTER A CARGO OPERATION
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_shipment_after_cargo_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment_id UUID;
BEGIN
  SELECT shipment_id
  INTO v_shipment_id
  FROM shipment_items
  WHERE id = NEW.shipment_item_id;

  IF v_shipment_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_ITEM_NOT_FOUND';
  END IF;

  PERFORM recalculate_shipment_status(v_shipment_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_cargo_status_recalculation
AFTER INSERT ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_shipment_after_cargo_operation();