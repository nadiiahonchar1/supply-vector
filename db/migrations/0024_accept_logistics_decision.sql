-- =============================================
-- 0024: ACCEPT LOGISTICS DECISION
-- =============================================

BEGIN;

CREATE OR REPLACE FUNCTION accept_logistics_decision(
  p_decision_id UUID,
  p_user_id UUID
)
RETURNS SETOF logistics_decisions
LANGUAGE plpgsql
AS $$
DECLARE
  v_decision logistics_decisions%ROWTYPE;
  v_shipment shipments%ROWTYPE;
  v_request transfer_requests%ROWTYPE;
  v_vehicle vehicles%ROWTYPE;

  v_trip_id UUID;
  v_pickup_stop_id UUID;
  v_dropoff_stop_id UUID;

  v_shipment_quantity INTEGER;
  v_assigned_quantity INTEGER;
  v_remaining_quantity INTEGER;

  v_vehicle_id UUID;
  v_inserted_items INTEGER;
BEGIN
  -- =============================================
  -- 1. LOCK AND VALIDATE DECISION
  -- =============================================

  SELECT *
  INTO v_decision
  FROM logistics_decisions
  WHERE id = p_decision_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'LOGISTICS_DECISION_NOT_FOUND'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_decision.decision_source <> 'system'
     OR v_decision.decision_status <> 'pending' THEN
    RAISE EXCEPTION 'LOGISTICS_DECISION_NOT_AVAILABLE'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_decision.shipment_id IS NULL
     OR v_decision.transfer_request_id IS NULL THEN
    RAISE EXCEPTION 'LOGISTICS_DECISION_INVALID'
      USING ERRCODE = 'P0001';
  END IF;

  -- =============================================
  -- 2. LOCK AND VALIDATE SHIPMENT
  -- =============================================

  SELECT *
  INTO v_shipment
  FROM shipments
  WHERE id = v_decision.shipment_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_shipment.status <> 'pending'
     OR v_shipment.transfer_request_id
        IS DISTINCT FROM v_decision.transfer_request_id THEN
    RAISE EXCEPTION 'LOGISTICS_SHIPMENT_NOT_AVAILABLE'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_decision.transfer_request_id
  FOR UPDATE;

  IF NOT FOUND OR v_request.status <> 'approved' THEN
    RAISE EXCEPTION 'LOGISTICS_REQUEST_NOT_AVAILABLE'
      USING ERRCODE = 'P0001';
  END IF;

  -- =============================================
  -- 3. CALCULATE REMAINING SHIPMENT QUANTITY
  -- =============================================

  SELECT COALESCE(SUM(quantity), 0)::INTEGER
  INTO v_shipment_quantity
  FROM shipment_items
  WHERE shipment_id = v_shipment.id;

  SELECT COALESCE(SUM(quantity), 0)::INTEGER
  INTO v_assigned_quantity
  FROM trip_items
  WHERE shipment_id = v_shipment.id;

  v_remaining_quantity :=
    v_shipment_quantity - v_assigned_quantity;

  IF v_remaining_quantity <= 0 THEN
    RAISE EXCEPTION 'LOGISTICS_SHIPMENT_ALREADY_ASSIGNED'
      USING ERRCODE = 'P0001';
  END IF;

  -- =============================================
  -- 4. PROCESS DECISION TYPE
  -- =============================================

  CASE v_decision.decision_type

    -- -------------------------------------------
    -- ADD TO EXISTING TRIP
    -- -------------------------------------------

    WHEN 'add_to_existing_trip' THEN

      IF v_decision.trip_id IS NULL THEN
        RAISE EXCEPTION 'LOGISTICS_TRIP_REQUIRED'
          USING ERRCODE = 'P0001';
      END IF;

      v_trip_id := v_decision.trip_id;

      PERFORM 1
      FROM trips
      WHERE id = v_trip_id
        AND status IN ('planned', 'ready')
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'LOGISTICS_TRIP_NOT_AVAILABLE'
          USING ERRCODE = 'P0001';
      END IF;

      SELECT id
      INTO v_pickup_stop_id
      FROM trip_stops
      WHERE trip_id = v_trip_id
        AND store_id = v_shipment.source_store_id
      ORDER BY sequence
      LIMIT 1;

      SELECT id
      INTO v_dropoff_stop_id
      FROM trip_stops
      WHERE trip_id = v_trip_id
        AND store_id = v_shipment.destination_store_id
        AND sequence > (
          SELECT sequence
          FROM trip_stops
          WHERE id = v_pickup_stop_id
        )
      ORDER BY sequence
      LIMIT 1;

      IF v_pickup_stop_id IS NULL
         OR v_dropoff_stop_id IS NULL THEN
        RAISE EXCEPTION 'LOGISTICS_TRIP_STOPS_NOT_AVAILABLE'
          USING ERRCODE = 'P0001';
      END IF;

    -- -------------------------------------------
    -- CREATE NEW TRIP
    -- -------------------------------------------

    WHEN 'create_new_trip' THEN

      IF v_decision.trip_id IS NOT NULL THEN
        RAISE EXCEPTION 'LOGISTICS_TRIP_NOT_ALLOWED'
          USING ERRCODE = 'P0001';
      END IF;

      IF v_decision.cost_breakdown->>'vehicle_id' IS NULL THEN
        RAISE EXCEPTION 'LOGISTICS_VEHICLE_REQUIRED'
          USING ERRCODE = 'P0001';
      END IF;

      v_vehicle_id :=
        (v_decision.cost_breakdown->>'vehicle_id')::UUID;

      SELECT *
      INTO v_vehicle
      FROM vehicles
      WHERE id = v_vehicle_id
        AND is_active = TRUE
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'LOGISTICS_VEHICLE_NOT_AVAILABLE'
          USING ERRCODE = 'P0001';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM trips
        WHERE vehicle_id = v_vehicle_id
          AND status IN ('ready', 'in_transit')
      ) THEN
        RAISE EXCEPTION 'LOGISTICS_VEHICLE_ALREADY_ASSIGNED'
          USING ERRCODE = 'P0001';
      END IF;

      INSERT INTO trips (
        vehicle_id,
        origin_store_id,
        status,
        distance_km,
        cost,
        created_by,
        updated_by
      )
      VALUES (
        v_vehicle_id,
        v_shipment.source_store_id,
        'planned',
        NULLIF(
          v_decision.cost_breakdown->>'distance_km',
          ''
        )::NUMERIC,
        v_decision.total_cost,
        p_user_id,
        p_user_id
      )
      RETURNING id INTO v_trip_id;

      INSERT INTO trip_stops (
        trip_id,
        store_id,
        sequence
      )
      VALUES (
        v_trip_id,
        v_shipment.source_store_id,
        1
      )
      RETURNING id INTO v_pickup_stop_id;

      INSERT INTO trip_stops (
        trip_id,
        store_id,
        sequence
      )
      VALUES (
        v_trip_id,
        v_shipment.destination_store_id,
        2
      )
      RETURNING id INTO v_dropoff_stop_id;

    -- -------------------------------------------
    -- DEFER
    -- -------------------------------------------

    WHEN 'defer' THEN

      UPDATE logistics_decisions
      SET
        decision_status = 'accepted',
        decided_by = p_user_id
      WHERE id = p_decision_id;

      RETURN QUERY
      SELECT *
      FROM logistics_decisions
      WHERE id = p_decision_id;

      RETURN;

    ELSE

      RAISE EXCEPTION 'LOGISTICS_DECISION_TYPE_INVALID'
        USING ERRCODE = 'P0001';

  END CASE;

  -- =============================================
  -- 5. ASSIGN REMAINING SHIPMENT QUANTITY
  -- =============================================

  PERFORM *
  FROM create_trip_item(
    v_trip_id,
    v_shipment.id,
    v_pickup_stop_id,
    v_dropoff_stop_id,
    v_remaining_quantity
  );

  GET DIAGNOSTICS v_inserted_items = ROW_COUNT;

  IF v_inserted_items = 0 THEN
    RAISE EXCEPTION 'LOGISTICS_TRIP_ITEM_NOT_CREATED'
      USING ERRCODE = 'P0001';
  END IF;

  -- =============================================
  -- 6. ACCEPT DECISION
  -- =============================================

  UPDATE logistics_decisions
  SET
    decision_status = 'accepted',
    decided_by = p_user_id,
    trip_id = v_trip_id
  WHERE id = p_decision_id;

  RETURN QUERY
  SELECT *
  FROM logistics_decisions
  WHERE id = p_decision_id;

END;
$$;

COMMIT;