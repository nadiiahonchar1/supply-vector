-- =====================================
-- ATOMIC SHIPMENT COMPLETION
-- =====================================

CREATE OR REPLACE FUNCTION complete_shipment(
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
  v_locked_source_count INTEGER;
  v_invalid_source_count INTEGER;

  v_item RECORD;
  v_source_quantity INTEGER;
  v_source_reserved_quantity INTEGER;
  v_destination_quantity INTEGER;
  v_affected_rows INTEGER;
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

  IF v_shipment.status <> 'in_transit' THEN
    RETURN;
  END IF;

  -- 2. Lock all requests linked to this shipment.
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

  -- 3. Validate shipment items.
  SELECT COUNT(*)
  INTO v_item_count
  FROM shipment_items
  WHERE shipment_id = p_shipment_id;

  IF v_item_count = 0 THEN
    RETURN;
  END IF;

  -- 4. Lock all existing source inventory rows.
  PERFORM 1
  FROM inventory i
  JOIN shipment_items si
    ON si.product_id = i.product_id
  WHERE i.store_id = v_shipment.source_store_id
    AND si.shipment_id = p_shipment_id
  ORDER BY i.id
  FOR UPDATE OF i;

  GET DIAGNOSTICS v_locked_source_count = ROW_COUNT;

  -- Every shipment item must have a source inventory row.
  IF v_locked_source_count <> v_item_count THEN
    RETURN;
  END IF;

  -- 5. Check available and reserved quantities before any writes.
  SELECT COUNT(*)
  INTO v_invalid_source_count
  FROM shipment_items si
  JOIN inventory i
    ON i.product_id = si.product_id
   AND i.store_id = v_shipment.source_store_id
  WHERE si.shipment_id = p_shipment_id
    AND (
      i.quantity < si.quantity
      OR i.reserved_quantity < si.quantity
    );

  IF v_invalid_source_count > 0 THEN
    RETURN;
  END IF;

  -- 6. Transfer every item.
  FOR v_item IN
    SELECT
      id AS shipment_item_id,
      product_id,
      quantity
    FROM shipment_items
    WHERE shipment_id = p_shipment_id
    ORDER BY product_id
  LOOP
    -- Read the locked source inventory row.
    SELECT
      quantity,
      reserved_quantity
    INTO
      v_source_quantity,
      v_source_reserved_quantity
    FROM inventory
    WHERE store_id = v_shipment.source_store_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'Source inventory changed during shipment completion';
    END IF;

    IF v_source_quantity < v_item.quantity
      OR v_source_reserved_quantity < v_item.quantity
    THEN
      RAISE EXCEPTION
        'Source inventory changed during shipment completion';
    END IF;

    -- Decrease stock and release the reservation.
    UPDATE inventory
    SET
      quantity = quantity - v_item.quantity,
      reserved_quantity = reserved_quantity - v_item.quantity,
      updated_at = NOW()
    WHERE store_id = v_shipment.source_store_id
      AND product_id = v_item.product_id
      AND quantity >= v_item.quantity
      AND reserved_quantity >= v_item.quantity;

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

    IF v_affected_rows <> 1 THEN
      RAISE EXCEPTION
        'Failed to update source inventory during shipment completion';
    END IF;

    -- Record the outgoing movement.
    INSERT INTO inventory_movements (
      store_id,
      product_id,
      quantity_change,
      quantity_before,
      quantity_after,
      movement_type,
      shipment_id,
      shipment_item_id,
      created_by
    )
    VALUES (
      v_shipment.source_store_id,
      v_item.product_id,
      -v_item.quantity,
      v_source_quantity,
      v_source_quantity - v_item.quantity,
      'transfer_out',
      p_shipment_id,
      v_item.shipment_item_id,
      p_user_id
    );

    -- Add stock to the destination and get the resulting quantity.
    INSERT INTO inventory (
      store_id,
      product_id,
      quantity,
      reserved_quantity
    )
    VALUES (
      v_shipment.destination_store_id,
      v_item.product_id,
      v_item.quantity,
      0
    )
    ON CONFLICT (store_id, product_id)
    DO UPDATE SET
      quantity = inventory.quantity + EXCLUDED.quantity,
      updated_at = NOW()
    RETURNING quantity INTO v_destination_quantity;

    -- Record the incoming movement.
    INSERT INTO inventory_movements (
      store_id,
      product_id,
      quantity_change,
      quantity_before,
      quantity_after,
      movement_type,
      shipment_id,
      shipment_item_id,
      created_by
    )
    VALUES (
      v_shipment.destination_store_id,
      v_item.product_id,
      v_item.quantity,
      v_destination_quantity - v_item.quantity,
      v_destination_quantity,
      'transfer_in',
      p_shipment_id,
      v_item.shipment_item_id,
      p_user_id
    );
  END LOOP;

  -- 7. Mark the transfer request as fulfilled.
  UPDATE transfer_requests
  SET
    status = 'fulfilled',
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = v_request.id
    AND shipment_id = p_shipment_id
    AND status IN ('pending', 'approved');

  GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

  IF v_affected_rows <> 1 THEN
    RAISE EXCEPTION
      'Failed to complete transfer request';
  END IF;

  -- 8. Mark the shipment as completed.
  UPDATE shipments
  SET
    status = 'completed',
    completed_at = NOW(),
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = p_shipment_id
    AND status = 'in_transit';

  GET DIAGNOSTICS v_affected_rows = ROW_COUNT;

  IF v_affected_rows <> 1 THEN
    RAISE EXCEPTION
      'Failed to complete shipment';
  END IF;

  -- 9. Return the updated shipment.
  RETURN QUERY
  SELECT s.*
  FROM shipments s
  WHERE s.id = p_shipment_id;
END;
$$;