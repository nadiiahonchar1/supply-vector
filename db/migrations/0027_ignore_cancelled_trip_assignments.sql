BEGIN;

-- =============================================
-- 0027: IGNORE CANCELLED TRIP ASSIGNMENTS
-- =============================================


-- =============================================
-- CREATE TRIP ITEM BY SHIPMENT
-- =============================================

CREATE OR REPLACE FUNCTION create_trip_item(
  p_trip_id UUID,
  p_shipment_id UUID,
  p_pickup_stop_id UUID,
  p_dropoff_stop_id UUID,
  p_quantity INTEGER
)
RETURNS SETOF trip_items
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment shipments%ROWTYPE;
  v_request_id UUID;

  v_shipment_quantity INTEGER;
  v_assigned_quantity INTEGER;

  v_trip_status TEXT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = p_shipment_id
  FOR UPDATE;

  IF NOT FOUND OR v_shipment.status <> 'pending' THEN
    RETURN;
  END IF;

  v_request_id := v_shipment.transfer_request_id;

  IF v_request_id IS NULL THEN
    RETURN;
  END IF;

  PERFORM 1
  FROM transfer_requests
  WHERE id = v_request_id
    AND status IN ('pending', 'approved')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(si.quantity), 0)::INTEGER
  INTO v_shipment_quantity
  FROM shipment_items si
  WHERE si.shipment_id = p_shipment_id;

  IF v_shipment_quantity <= 0 THEN
    RETURN;
  END IF;

  -- Ignore assignments belonging to cancelled trips.
  SELECT COALESCE(SUM(ti.quantity), 0)::INTEGER
  INTO v_assigned_quantity
  FROM trip_items ti
  JOIN trips t ON t.id = ti.trip_id
  WHERE ti.shipment_id = p_shipment_id
    AND t.status <> 'cancelled';

  IF v_assigned_quantity + p_quantity > v_shipment_quantity THEN
    RETURN;
  END IF;

  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND OR v_trip_status NOT IN ('planned', 'ready') THEN
    RETURN;
  END IF;

  IF p_pickup_stop_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM trip_stops ts
    WHERE ts.id = p_pickup_stop_id
      AND ts.trip_id = p_trip_id
      AND ts.store_id = v_shipment.source_store_id
  ) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM trip_stops ts
    WHERE ts.id = p_dropoff_stop_id
      AND ts.trip_id = p_trip_id
      AND ts.store_id = v_shipment.destination_store_id
  ) THEN
    RETURN;
  END IF;

  IF NOT trip_item_fits_capacity(
    p_trip_id,
    p_shipment_id,
    p_quantity
  ) THEN
    RAISE EXCEPTION 'TRIP_CAPACITY_EXCEEDED'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  INSERT INTO trip_items (
    trip_id,
    shipment_id,
    transfer_request_id,
    pickup_stop_id,
    dropoff_stop_id,
    quantity
  )
  VALUES (
    p_trip_id,
    p_shipment_id,
    v_request_id,
    p_pickup_stop_id,
    p_dropoff_stop_id,
    p_quantity
  )
  RETURNING *;
END;
$$;


-- =============================================
-- UPDATE TRIP ITEM
-- =============================================

CREATE OR REPLACE FUNCTION update_trip_item(
  p_id UUID,
  p_pickup_stop_id UUID,
  p_dropoff_stop_id UUID,
  p_quantity INTEGER
)
RETURNS SETOF trip_items
LANGUAGE plpgsql
AS $$
DECLARE
  v_item trip_items%ROWTYPE;
  v_shipment shipments%ROWTYPE;

  v_shipment_quantity INTEGER;
  v_assigned_quantity INTEGER;

  v_trip_status TEXT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_item
  FROM trip_items
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND OR v_item.shipment_id IS NULL THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = v_item.shipment_id
  FOR UPDATE;

  IF NOT FOUND OR v_shipment.status <> 'pending' THEN
    RETURN;
  END IF;

  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = v_item.trip_id
  FOR UPDATE;

  IF NOT FOUND OR v_trip_status NOT IN ('planned', 'ready') THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(si.quantity), 0)::INTEGER
  INTO v_shipment_quantity
  FROM shipment_items si
  WHERE si.shipment_id = v_item.shipment_id;

  -- Ignore cancelled trips and exclude the item being updated.
  SELECT COALESCE(SUM(ti.quantity), 0)::INTEGER
  INTO v_assigned_quantity
  FROM trip_items ti
  JOIN trips t ON t.id = ti.trip_id
  WHERE ti.shipment_id = v_item.shipment_id
    AND ti.id <> p_id
    AND t.status <> 'cancelled';

  IF v_assigned_quantity + p_quantity > v_shipment_quantity THEN
    RETURN;
  END IF;

  IF p_pickup_stop_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM trip_stops ts
    WHERE ts.id = p_pickup_stop_id
      AND ts.trip_id = v_item.trip_id
      AND ts.store_id = v_shipment.source_store_id
  ) THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM trip_stops ts
    WHERE ts.id = p_dropoff_stop_id
      AND ts.trip_id = v_item.trip_id
      AND ts.store_id = v_shipment.destination_store_id
  ) THEN
    RETURN;
  END IF;

  IF NOT trip_item_fits_capacity(
    v_item.trip_id,
    v_item.shipment_id,
    p_quantity,
    p_id
  ) THEN
    RAISE EXCEPTION 'TRIP_CAPACITY_EXCEEDED'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  UPDATE trip_items
  SET
    pickup_stop_id = p_pickup_stop_id,
    dropoff_stop_id = p_dropoff_stop_id,
    quantity = p_quantity
  WHERE id = p_id
  RETURNING *;
END;
$$;

COMMIT;