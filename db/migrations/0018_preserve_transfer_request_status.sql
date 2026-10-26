
-- =============================================
-- 0018: PRESERVE TRANSFER REQUEST STATUS
-- =============================================
-- A partial shipment must not automatically approve
-- a transfer request that was still pending.
-- Only fully delivered requests become fulfilled.

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
  v_item RECORD;
  v_inventory inventory%ROWTYPE;
  v_destination_quantity INTEGER;
  v_delivered_quantity INTEGER;
BEGIN  
  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF NOT FOUND OR v_shipment.status <> 'in_transit' THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_shipment.transfer_request_id
     OR shipment_id = v_shipment.id
  ORDER BY CASE
    WHEN id = v_shipment.transfer_request_id THEN 0
    ELSE 1
  END
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_request.status NOT IN ('pending', 'approved') THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM shipment_items
    WHERE shipment_id = v_shipment.id
  ) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM shipment_items
    WHERE shipment_id = v_shipment.id
      AND product_id <> v_request.product_id
  ) THEN
    RAISE EXCEPTION
      'Shipment item does not match transfer request product';
  END IF;

  IF v_shipment.source_store_id <> v_request.source_store_id
     OR v_shipment.destination_store_id <> v_request.destination_store_id
  THEN
    RAISE EXCEPTION
      'Shipment stores do not match transfer request';
  END IF;

  PERFORM 1
  FROM inventory i
  JOIN shipment_items si
    ON si.product_id = i.product_id
  WHERE i.store_id = v_shipment.source_store_id
    AND si.shipment_id = v_shipment.id
  ORDER BY i.id
  FOR UPDATE OF i;

  IF EXISTS (
    SELECT 1
    FROM shipment_items si
    LEFT JOIN inventory i
      ON i.store_id = v_shipment.source_store_id
     AND i.product_id = si.product_id
    WHERE si.shipment_id = v_shipment.id
      AND (
        i.id IS NULL
        OR i.quantity < si.quantity
        OR i.reserved_quantity < si.quantity
      )
  ) THEN
    RAISE EXCEPTION
      'Insufficient stock or reservation to complete shipment';
  END IF;

  FOR v_item IN
    SELECT id AS shipment_item_id, product_id, quantity
    FROM shipment_items
    WHERE shipment_id = v_shipment.id
    ORDER BY product_id
  LOOP
    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE store_id = v_shipment.source_store_id
      AND product_id = v_item.product_id
    FOR UPDATE;

    UPDATE inventory
    SET
      quantity = quantity - v_item.quantity,
      reserved_quantity = reserved_quantity - v_item.quantity,
      updated_at = NOW()
    WHERE id = v_inventory.id
      AND quantity >= v_item.quantity
      AND reserved_quantity >= v_item.quantity;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'Failed to update source inventory during shipment completion';
    END IF;

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
      v_inventory.quantity,
      v_inventory.quantity - v_item.quantity,
      'transfer_out',
      v_shipment.id,
      v_item.shipment_item_id,
      p_user_id
    );

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
      v_shipment.id,
      v_item.shipment_item_id,
      p_user_id
    );
  END LOOP;

  UPDATE inventory_reservations
  SET released_at = NOW()
  WHERE shipment_id = v_shipment.id
    AND released_at IS NULL;

  UPDATE shipments
  SET
    status = 'completed',
    completed_at = NOW(),
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = v_shipment.id
    AND status = 'in_transit'
  RETURNING * INTO v_shipment;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to complete shipment';
  END IF;
 
  SELECT COALESCE(SUM(si.quantity), 0)::INTEGER
  INTO v_delivered_quantity
  FROM shipments s
  JOIN shipment_items si
    ON si.shipment_id = s.id
  WHERE s.transfer_request_id = v_request.id
    AND s.status = 'completed';
 
  IF v_request.shipment_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM shipments s
       WHERE s.id = v_request.shipment_id
         AND s.transfer_request_id = v_request.id
     )
  THEN
    SELECT
      v_delivered_quantity
      + COALESCE(SUM(si.quantity), 0)::INTEGER
    INTO v_delivered_quantity
    FROM shipments s
    JOIN shipment_items si
      ON si.shipment_id = s.id
    WHERE s.id = v_request.shipment_id
      AND s.status = 'completed';
  END IF;

 
  UPDATE transfer_requests
  SET
    status = CASE
      WHEN v_delivered_quantity >= quantity THEN 'fulfilled'
      ELSE v_request.status
    END,
    updated_by = p_user_id,
    updated_at = NOW()
  WHERE id = v_request.id;

  RETURN NEXT v_shipment;
END;
$$;
