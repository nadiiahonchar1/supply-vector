-- =====================================
-- TRIP CAPACITY VALIDATION
-- =====================================

CREATE OR REPLACE FUNCTION trip_item_fits_capacity(
  p_trip_id UUID,
  p_transfer_request_id UUID,
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
  FROM transfer_requests tr
  JOIN products p ON p.id = tr.product_id
  WHERE tr.id = p_transfer_request_id;

  IF NOT FOUND OR v_product_weight IS NULL THEN
    RETURN FALSE;
  END IF;

  IF v_capacity_volume IS NOT NULL
     AND v_product_volume IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT
    COALESCE(
      SUM(ti.quantity * p.weight_kg),
      0
    ),
    COALESCE(
      SUM(ti.quantity * p.volume_m3),
      0
    ),
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
  JOIN transfer_requests tr
    ON tr.id = ti.transfer_request_id
  LEFT JOIN products p
    ON p.id = tr.product_id
  WHERE ti.trip_id = p_trip_id
    AND (
      p_exclude_trip_item_id IS NULL
      OR ti.id <> p_exclude_trip_item_id
    );

  -- Do not approve a load whose weight is unknown.
  IF v_missing_weights > 0 THEN
    RETURN FALSE;
  END IF;

  -- Volume is required when the vehicle has a volume limit.
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


-- =====================================
-- CREATE TRIP ITEM
-- =====================================

CREATE OR REPLACE FUNCTION create_trip_item(
  p_trip_id UUID,
  p_transfer_request_id UUID,
  p_pickup_stop_id UUID,
  p_dropoff_stop_id UUID,
  p_quantity INTEGER
)
RETURNS SETOF trip_items
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_quantity INTEGER;
  v_assigned INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN;
  END IF;

  SELECT tr.quantity
  INTO v_request_quantity
  FROM transfer_requests tr
  WHERE tr.id = p_transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(ti.quantity), 0)
  INTO v_assigned
  FROM trip_items ti
  WHERE ti.transfer_request_id = p_transfer_request_id;

  IF v_assigned + p_quantity > v_request_quantity THEN
    RETURN;
  END IF;

  -- Serialize item changes for the same trip.
  PERFORM 1
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF NOT trip_item_fits_capacity(
    p_trip_id,
    p_transfer_request_id,
    p_quantity
  ) THEN
    RAISE EXCEPTION 'TRIP_CAPACITY_EXCEEDED'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  INSERT INTO trip_items (
    trip_id,
    transfer_request_id,
    pickup_stop_id,
    dropoff_stop_id,
    quantity
  )
  VALUES (
    p_trip_id,
    p_transfer_request_id,
    p_pickup_stop_id,
    p_dropoff_stop_id,
    p_quantity
  )
  RETURNING *;
END;
$$;


-- =====================================
-- UPDATE TRIP ITEM
-- =====================================

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
  v_trip_id UUID;
  v_request_id UUID;
  v_request_quantity INTEGER;
  v_assigned_by_others INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN;
  END IF;

  SELECT
    ti.trip_id,
    ti.transfer_request_id
  INTO
    v_trip_id,
    v_request_id
  FROM trip_items ti
  WHERE ti.id = p_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT tr.quantity
  INTO v_request_quantity
  FROM transfer_requests tr
  WHERE tr.id = v_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(ti.quantity), 0)
  INTO v_assigned_by_others
  FROM trip_items ti
  WHERE ti.transfer_request_id = v_request_id
    AND ti.id <> p_id;

  IF v_assigned_by_others + p_quantity > v_request_quantity THEN
    RETURN;
  END IF;

  -- Serialize item changes for the same trip.
  PERFORM 1
  FROM trips
  WHERE id = v_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF NOT trip_item_fits_capacity(
    v_trip_id,
    v_request_id,
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