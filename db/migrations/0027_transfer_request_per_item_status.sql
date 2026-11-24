-- =========================================================
-- 1. APPLICATION STATUS RECALCULATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_transfer_request_status(
  p_transfer_request_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;

  v_total_items INTEGER := 0;
  v_completed_items INTEGER := 0;

  v_total_requested BIGINT := 0;
  v_total_received BIGINT := 0;
  v_total_cancelled BIGINT := 0;

  v_any_loaded BOOLEAN := FALSE;
  v_any_received BOOLEAN := FALSE;

  v_new_status TEXT;
BEGIN
  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status IN (
    'fulfilled',
    'partially_fulfilled',
    'cancelled'
  ) THEN
    RETURN v_request.status;
  END IF;

  IF v_request.status IN ('draft', 'pending') THEN
    RETURN v_request.status;
  END IF;

  -- =======================================================
  -- 2. COUNTING OF EACH PRODUCT ITEM
  -- =======================================================

  SELECT
    COUNT(*)::INTEGER,

    COALESCE(SUM(tri.requested_quantity), 0),

    COALESCE(SUM(tri.cancelled_quantity), 0),

    COALESCE(SUM(item_totals.received_quantity), 0),

    COALESCE(
      BOOL_OR(item_totals.loaded_quantity > 0),
      FALSE
    ),

    COALESCE(
      BOOL_OR(item_totals.received_quantity > 0),
      FALSE
    ),

    COALESCE(
      BOOL_AND(
        item_totals.received_quantity
        + tri.cancelled_quantity
        >= tri.requested_quantity
      ),
      FALSE
    )

  INTO
    v_total_items,
    v_total_requested,
    v_total_cancelled,
    v_total_received,
    v_any_loaded,
    v_any_received,
    v_completed_items

  FROM transfer_request_items tri

  LEFT JOIN LATERAL (
    SELECT
      COALESCE((
        SELECT SUM(srm.quantity)
        FROM shipment_receipt_movements srm
        JOIN shipment_items si
          ON si.id = srm.shipment_item_id
        JOIN transfer_request_sources trs
          ON trs.id = si.transfer_request_source_id
        WHERE trs.transfer_request_item_id = tri.id
      ), 0) AS received_quantity,

      COALESCE((
        SELECT SUM(slm.quantity)
        FROM shipment_loading_movements slm
        JOIN shipment_items si
          ON si.id = slm.shipment_item_id
        JOIN transfer_request_sources trs
          ON trs.id = si.transfer_request_source_id
        WHERE trs.transfer_request_item_id = tri.id
      ), 0) AS loaded_quantity

  ) item_totals ON TRUE

  WHERE tri.transfer_request_id = p_transfer_request_id;


  IF v_total_items = 0 THEN
    RAISE EXCEPTION
      'У заявці немає товарних позицій';
  END IF;


  -- =======================================================
  -- 3. DETERMINATION OF NEW STATUS
  -- =======================================================

  IF v_completed_items THEN

    IF v_total_received = 0 THEN
      v_new_status := 'cancelled';

    ELSIF v_total_cancelled > 0 THEN
      v_new_status := 'partially_fulfilled';

    ELSE
      v_new_status := 'fulfilled';
    END IF;

  ELSIF v_any_loaded OR v_any_received THEN

    v_new_status := 'in_progress';

  ELSE

    v_new_status := 'approved';

  END IF;


  -- =======================================================
  -- 4. CHANGE OF STATUS
  -- =======================================================

  IF v_new_status <> v_request.status THEN

    PERFORM set_config(
      'app.status_change_reason',
      'Автоматичний перерахунок за фактичними операціями з товарами',
      TRUE
    );

    UPDATE transfer_requests
    SET status = v_new_status,
        updated_at = NOW()
    WHERE id = p_transfer_request_id;

  END IF;

  RETURN v_new_status;
END;
$$;


-- =========================================================
-- 5. RECALCULATION AFTER RECEIPT OF GOODS
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_receipt()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT trs.transfer_request_id
  INTO v_request_id
  FROM shipment_items si
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS
  recalculate_request_after_receipt
ON shipment_receipt_movements;

CREATE TRIGGER recalculate_request_after_receipt
AFTER INSERT
ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_request_after_receipt();


-- =========================================================
-- 6. RECALCULATION AFTER LOADING
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_loading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT trs.transfer_request_id
  INTO v_request_id
  FROM shipment_items si
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS
  recalculate_request_after_loading
ON shipment_loading_movements;

CREATE TRIGGER recalculate_request_after_loading
AFTER INSERT
ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_request_after_loading();


-- =========================================================
-- 7. RECALCULATION AFTER CANCELLATION OF QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_cancellation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  SELECT transfer_request_id
  INTO v_request_id
  FROM transfer_request_items
  WHERE id = NEW.transfer_request_item_id;

  IF v_request_id IS NOT NULL THEN
    PERFORM recalculate_transfer_request_status(v_request_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS
  recalculate_request_after_cancellation
ON transfer_request_item_cancellations;

CREATE TRIGGER recalculate_request_after_cancellation
AFTER INSERT
ON transfer_request_item_cancellations
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_request_after_cancellation();


-- =========================================================
-- 8. RECALCULATION AFTER CHANGING THE QUANTITY OF AN ITEM
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_item_quantity_change()
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

DROP TRIGGER IF EXISTS
  recalculate_request_after_item_quantity_change
ON transfer_request_items;

CREATE TRIGGER recalculate_request_after_item_quantity_change
AFTER UPDATE OF requested_quantity, cancelled_quantity
ON transfer_request_items
FOR EACH ROW
WHEN (
  OLD.requested_quantity IS DISTINCT FROM NEW.requested_quantity
  OR OLD.cancelled_quantity IS DISTINCT FROM NEW.cancelled_quantity
)
EXECUTE FUNCTION trigger_recalculate_request_after_item_quantity_change();