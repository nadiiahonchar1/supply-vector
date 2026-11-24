-- =========================================================
-- 1. EXPANSION OF PERMITTED STATUSES
-- =========================================================

ALTER TABLE shipments
DROP CONSTRAINT IF EXISTS shipments_status_check;

ALTER TABLE shipments
ADD CONSTRAINT shipments_status_check
CHECK (
  status IN (
    'pending',
    'in_progress',
    'partially_delivered',
    'delivered',
    'returned',
    'lost',
    'settled',
    'partially_fulfilled',
    'cancelled'
  )
);


-- =========================================================
-- 2. SHIPMENT STATUS RECALCULATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_shipment_status(
  p_shipment_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;

  v_planned INTEGER := 0;
  v_loaded INTEGER := 0;
  v_received INTEGER := 0;

  v_returned INTEGER := 0;
  v_lost INTEGER := 0;
  v_written_off INTEGER := 0;
  v_transferred INTEGER := 0;

  v_resolved INTEGER := 0;
  v_unresolved INTEGER := 0;

  v_new_status TEXT;
BEGIN
  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Відправлення не знайдено';
  END IF;

  IF v_shipment.status = 'cancelled' THEN
    RETURN 'cancelled';
  END IF;

  SELECT COALESCE(SUM(planned_quantity), 0)
  INTO v_planned
  FROM shipment_items
  WHERE shipment_id = p_shipment_id;

  SELECT COALESCE(SUM(slm.quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements slm
  JOIN shipment_items si
    ON si.id = slm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id;

  SELECT COALESCE(SUM(srm.quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements srm
  JOIN shipment_items si
    ON si.id = srm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id;

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_returned
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id
    AND scm.movement_type = 'return';

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_lost
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id
    AND scm.movement_type = 'loss';

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_written_off
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id
    AND scm.movement_type = 'writeoff';

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_transferred
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  WHERE si.shipment_id = p_shipment_id
    AND scm.movement_type = 'responsibility_transfer';

  v_resolved :=
    v_returned
    + v_lost
    + v_written_off
    + v_transferred;

  v_unresolved := v_loaded - v_received - v_resolved;

  IF v_unresolved < 0 THEN
    RAISE EXCEPTION
      'Виявлено некоректний баланс вантажу у відправленні';
  END IF;

  IF v_loaded = 0 THEN
    IF v_shipment.status = 'in_progress' THEN
      v_new_status := 'in_progress';
    ELSE
      v_new_status := 'pending';
    END IF;

  ELSIF v_received = v_loaded THEN
    v_new_status := 'delivered';

  ELSIF v_received > 0 AND v_unresolved > 0 THEN
    v_new_status := 'partially_delivered';

  ELSIF v_received > 0 AND v_unresolved = 0 THEN
    v_new_status := 'partially_fulfilled';

  ELSIF v_returned = v_loaded
     AND v_lost = 0
     AND v_written_off = 0
     AND v_transferred = 0 THEN
    v_new_status := 'returned';

  ELSIF v_lost = v_loaded
     AND v_returned = 0
     AND v_written_off = 0
     AND v_transferred = 0 THEN
    v_new_status := 'lost';

  ELSIF v_unresolved = 0 THEN
    v_new_status := 'settled';

  ELSE
    v_new_status := 'in_progress';
  END IF;

  UPDATE shipments
  SET
    status = v_new_status,
    updated_at = NOW()
  WHERE id = p_shipment_id;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 3. RECALCULATION AFTER PHYSICAL RECEIPT
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_after_receipt()
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

  PERFORM recalculate_shipment_status(v_shipment_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_receipt_recalculate_status
AFTER INSERT ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_after_receipt();


-- =========================================================
-- 4. RECALCULATION FOLLOWING THE DETERMINATION OF THE CARGO'S FATE
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_after_cargo_resolution()
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

  PERFORM recalculate_shipment_status(v_shipment_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_cargo_recalculate_status
AFTER INSERT ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_after_cargo_resolution();


-- =========================================================
-- 5. RECALCULATION AFTER LOADING
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_after_loading()
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

  PERFORM recalculate_shipment_status(v_shipment_id);

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_loading_recalculate_status
AFTER INSERT ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_after_loading();