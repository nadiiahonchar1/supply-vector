-- =============================================
-- 0019: TRIP ITEMS BY SHIPMENT
-- =============================================


-- =============================================
-- CHECK TRIP CAPACITY BY SHIPMENT
-- =============================================

CREATE OR REPLACE FUNCTION trip_item_fits_capacity(
  p_trip_id UUID,
  p_shipment_id UUID,
  p_quantity INTEGER,
  p_exclude_trip_item_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_capacity_weight NUMERIC;
  v_capacity_volume NUMERIC;

  v_product_weight NUMERIC;
  v_product_volume NUMERIC;

  v_loaded_weight NUMERIC;
  v_loaded_volume NUMERIC;

  v_missing_weights BIGINT;
  v_missing_volumes BIGINT;
BEGIN
  SELECT
    v.capacity_weight,
    v.capacity_volume
  INTO
    v_capacity_weight,
    v_capacity_volume
  FROM trips t
  JOIN vehicles v ON v.id = t.vehicle_id
  WHERE t.id = p_trip_id;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  SELECT
    p.weight_kg,
    p.volume_m3
  INTO
    v_product_weight,
    v_product_volume
  FROM shipments s
  JOIN shipment_items si
    ON si.shipment_id = s.id
  JOIN products p
    ON p.id = si.product_id
  WHERE s.id = p_shipment_id;

  IF NOT FOUND OR v_product_weight IS NULL THEN
    RETURN FALSE;
  END IF;

  IF v_capacity_volume IS NOT NULL
     AND v_product_volume IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT
    COALESCE(SUM(ti.quantity * p.weight_kg), 0),
    COALESCE(SUM(ti.quantity * p.volume_m3), 0),

    COUNT(*) FILTER (
      WHERE p.weight_kg IS NULL
    ),

    COUNT(*) FILTER (
      WHERE v_capacity_volume IS NOT NULL
        AND p.volume_m3 IS NULL
    )
  INTO
    v_loaded_weight,
    v_loaded_volume,
    v_missing_weights,
    v_missing_volumes
  FROM trip_items ti
  JOIN shipments s
    ON s.id = ti.shipment_id
  JOIN shipment_items si
    ON si.shipment_id = s.id
  LEFT JOIN products p
    ON p.id = si.product_id
  WHERE ti.trip_id = p_trip_id
    AND (
      p_exclude_trip_item_id IS NULL
      OR ti.id <> p_exclude_trip_item_id
    );

  IF v_missing_weights > 0 THEN
    RETURN FALSE;
  END IF;

  IF v_missing_volumes > 0 THEN
    RETURN FALSE;
  END IF;

  IF v_loaded_weight
       + p_quantity * v_product_weight
     > v_capacity_weight THEN
    RETURN FALSE;
  END IF;

  IF v_capacity_volume IS NOT NULL
     AND v_loaded_volume
       + p_quantity * v_product_volume
     > v_capacity_volume THEN
    RETURN FALSE;
  END IF;

  RETURN TRUE;
END;
$$;


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

  SELECT COALESCE(SUM(ti.quantity), 0)::INTEGER
  INTO v_assigned_quantity
  FROM trip_items ti
  WHERE ti.shipment_id = p_shipment_id;

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

  IF NOT EXISTS (
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

  SELECT COALESCE(SUM(ti.quantity), 0)::INTEGER
  INTO v_assigned_quantity
  FROM trip_items ti
  WHERE ti.shipment_id = v_item.shipment_id
    AND ti.id <> p_id;

  IF v_assigned_quantity + p_quantity > v_shipment_quantity THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
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