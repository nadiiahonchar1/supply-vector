-- =====================================
-- SUM OF TRIP_ITEMS MUS NOT EXCEED THE TRANSFER REQUEST
-- =====================================

CREATE OR REPLACE FUNCTION create_trip_item(
  p_trip_id uuid,
  p_transfer_request_id uuid,
  p_pickup_stop_id uuid,
  p_dropoff_stop_id uuid,
  p_quantity integer
)
RETURNS SETOF trip_items
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_quantity integer;
  v_assigned integer;
BEGIN
  -- Serialize all assignments for this transfer request.
  SELECT tr.quantity
  INTO v_request_quantity
  FROM transfer_requests tr
  WHERE tr.id = p_transfer_request_id
  FOR UPDATE;
 
  IF NOT FOUND THEN
    RETURN;
  END IF;
 
  -- A new statement: fresh snapshot, taken after the lock above was granted.
  SELECT COALESCE(SUM(ti.quantity), 0)
  INTO v_assigned
  FROM trip_items ti
  WHERE ti.transfer_request_id = p_transfer_request_id;
 
  IF v_assigned + p_quantity > v_request_quantity THEN
    RETURN;
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
 
CREATE OR REPLACE FUNCTION update_trip_item(
  p_id uuid,
  p_pickup_stop_id uuid,
  p_dropoff_stop_id uuid,
  p_quantity integer
)
RETURNS SETOF trip_items
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id uuid;
  v_request_quantity integer;
  v_assigned_by_others integer;
BEGIN
  SELECT ti.transfer_request_id
  INTO v_request_id
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