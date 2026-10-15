-- =====================================
-- ATOMIC SHIPMENT CANCELLATION
-- =====================================

CREATE OR REPLACE FUNCTION cancel_shipment(
  p_shipment_id UUID,
  p_user_id UUID
)
RETURNS SETOF shipments
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment shipments%ROWTYPE;
  v_request transfer_requests%ROWTYPE;

  v_request_count INTEGER;
  v_item_count INTEGER;
  v_locked_inventory_count INTEGER;
  v_invalid_inventory_count INTEGER;
  v_affected_rows INTEGER;

  v_item RECORD;
BEGIN
  -- 1. Lock the shipment and validate its status.
  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_shipment.status <> 'pending' THEN
    RETURN;
  END IF;

  -- 2. Lock all transfer requests linked to this shipment.
  PERFORM 1
  FROM transfer_requests
  WHERE shipment_id = p_shipment_id
  ORDER BY id
  FOR UPDATE;

  GET DIAGNOSTICS v_request_count = ROW_COUNT;

  -- A shipment must belong to exactly one transfer request.
  IF v_request_count <> 1 THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE shipment_id = p_shipment_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_request.status NOT IN ('pending', 'approved') THEN
    RETURN;
  END IF;

  -- 3. Ensure the shipment has at least one item.
  SELECT COUNT(*)
  INTO v_item_count
  FROM shipment_items
  WHERE shipment_id = p_shipment_id;

  IF v_item_count = 0 THEN
    RETURN;
  END IF;

  -- 4. Lock all source inventory rows in a consistent order.
  PERFORM 1
  FROM inventory i
  JOIN shipment_items si
    ON si.product_id = i.product_id
  WHERE i.store_id = v_shipment.source_store_id
    AND si.shipment_id = p_shipment_id
  ORDER BY i.id
  FOR UPDATE OF i;

  GET DIAGNOSTICS v_locked_inventory_count = ROW_COUNT;

  -- Every shipment item must have a corresponding inventory row.
  IF v_locked_inventory_count <> v_item_count THEN
    RETURN;
  END IF;

  -- 5. Validate every reservation before changing anything.
  SELECT COUNT(*)
  INTO v_invalid_inventory_count
  FROM shipment_items si
  JOIN inventory i
    ON i.product_id = si.product_id
   AND i.store_id = v_shipment.source_store_id
  WHERE si.shipment_id = p_shipment_id
    AND i.reserved_quantity < si.quantity;

  IF v_invalid_inventory_count > 0 THEN
    RETURN;
  END IF;

  -- 6. Release the reservations.
  FOR v_item IN
    SELECT
      product_id,
      quantity
    FROM shipment_items
    WHERE shipment_id = p_shipment_id
    ORDER BY product_id
  LOOP
    UPDATE inventory
    SET
      reserved_quantity = reserved_quantity - v_item.quantity,
      updated_at = NOW()
    WHERE store_id = v_shipment.source_store_id
      AND product_id = v_item.product_id
      AND reserved_quantity >= v_item.quantity;

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
      RAISE EXCEPTION
        'Failed to release inventory reservation during shipment cancellation';
    END IF;
  END LOOP;

  -- 7. Cancel the linked transfer request.
  UPDATE transfer_requests
  SET
    status = 'cancelled',
    cancelled_at = NOW(),
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = v_request.id
    AND shipment_id = p_shipment_id
    AND status IN ('pending', 'approved');

  GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

  IF v_affected_rows <> 1 THEN
    RAISE EXCEPTION
      'Failed to cancel transfer request';
  END IF;

  -- 8. Cancel the shipment.
  UPDATE shipments
  SET
    status = 'cancelled',
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = p_shipment_id
    AND status = 'pending';

  GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

  IF v_affected_rows <> 1 THEN
    RAISE EXCEPTION
      'Failed to cancel shipment';
  END IF;

  -- 9. Return the updated shipment.
  RETURN QUERY
  SELECT s.*
  FROM shipments s
  WHERE s.id = p_shipment_id;
END;
$$;