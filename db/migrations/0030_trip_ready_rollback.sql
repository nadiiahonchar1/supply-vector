-- =========================================================
-- 1. PERMISSION TO RETURN A READY TRIP TO PLANNING
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'trip_return_to_planned',
  'Return trip to planning'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. TRIP PLANNING RETURN HISTORY
-- =========================================================

CREATE TABLE trip_planning_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL
    REFERENCES trips(id) ON DELETE RESTRICT,

  previous_route_version INTEGER NOT NULL
    CHECK (previous_route_version > 0),

  new_route_version INTEGER NOT NULL
    CHECK (new_route_version > previous_route_version),

  reason TEXT NOT NULL,

  returned_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  operation_key UUID NOT NULL UNIQUE,

  returned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT trip_planning_returns_reason_check
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000)
);

CREATE INDEX trip_planning_returns_trip_idx
  ON trip_planning_returns(trip_id, returned_at DESC);


-- =========================================================
-- 3. IMMUTABLE PLANNING RETURN HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_planning_return_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'trip_planning_return_history_is_immutable';
END;
$$;

CREATE TRIGGER trip_planning_returns_immutable
BEFORE UPDATE OR DELETE
ON trip_planning_returns
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_planning_return_mutation();


-- =========================================================
-- 4. PERMISSION CHECK
-- =========================================================

CREATE OR REPLACE FUNCTION user_can_return_trip_to_planned(
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM users u
    JOIN user_roles ur
      ON ur.user_id = u.id
    JOIN role_permissions rp
      ON rp.role_id = ur.role_id
    JOIN permissions p
      ON p.id = rp.permission_id
    WHERE u.id = p_user_id
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
      AND p.code = 'trip_return_to_planned'
  );
$$;


-- =========================================================
-- 5. RETURN A READY TRIP TO PLANNING
-- =========================================================

CREATE OR REPLACE FUNCTION return_trip_to_planned(
  p_trip_id UUID,
  p_user_id UUID,
  p_reason TEXT,
  p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
  v_existing RECORD;

  v_return_id UUID;
  v_new_route_version INTEGER;
  v_new_route_snapshot JSONB;
BEGIN
  IF p_trip_id IS NULL
     OR p_user_id IS NULL
     OR p_operation_key IS NULL THEN
    RAISE EXCEPTION 'required_parameter_is_missing';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL
     OR LENGTH(TRIM(p_reason)) > 2000 THEN
    RAISE EXCEPTION 'invalid_trip_return_reason';
  END IF;

  IF NOT user_can_return_trip_to_planned(p_user_id) THEN
    RAISE EXCEPTION 'permission_denied';
  END IF;

  SELECT *
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trip_not_found';
  END IF;

  SELECT *
  INTO v_existing
  FROM trip_planning_returns
  WHERE operation_key = p_operation_key;

  IF FOUND THEN
    IF v_existing.trip_id IS DISTINCT FROM p_trip_id
       OR v_existing.returned_by IS DISTINCT FROM p_user_id
       OR v_existing.reason IS DISTINCT FROM TRIM(p_reason) THEN
      RAISE EXCEPTION 'operation_key_payload_mismatch';
    END IF;

    RETURN v_existing.id;
  END IF;

  IF v_trip.status <> 'ready' THEN
    RAISE EXCEPTION 'trip_must_be_ready_to_return_to_planning';
  END IF;

  IF v_trip.actual_departure_at IS NOT NULL THEN
    RAISE EXCEPTION 'trip_has_already_departed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM trip_stops
    WHERE trip_id = p_trip_id
      AND (
        actual_arrival_at IS NOT NULL
        OR actual_departure_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'trip_has_recorded_stop_activity';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM trip_route_versions
    WHERE trip_id = p_trip_id
      AND version_number = v_trip.route_version
  ) THEN
    RAISE EXCEPTION 'current_trip_route_version_not_found';
  END IF;

  SELECT COALESCE(
    JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'stop_id', ts.id,
        'sequence', ts.sequence_number,
        'storage_point_id', ts.storage_point_id
      )
      ORDER BY ts.sequence_number
    ),
    '[]'::JSONB
  )
  INTO v_new_route_snapshot
  FROM trip_stops ts
  WHERE ts.trip_id = p_trip_id;

  IF JSONB_ARRAY_LENGTH(v_new_route_snapshot) < 2 THEN
    RAISE EXCEPTION 'trip_route_requires_at_least_two_stops';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT
        sequence_number,
        ROW_NUMBER() OVER (ORDER BY sequence_number) AS expected_sequence
      FROM trip_stops
      WHERE trip_id = p_trip_id
    ) route_sequence
    WHERE sequence_number <> expected_sequence
  ) THEN
    RAISE EXCEPTION 'trip_route_sequence_is_not_contiguous';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_new_route_version
  FROM trip_route_versions
  WHERE trip_id = p_trip_id;

  INSERT INTO trip_route_versions (
    trip_id,
    version_number,
    reason,
    route_snapshot,
    created_by
  )
  VALUES (
    p_trip_id,
    v_new_route_version,
    TRIM(p_reason),
    v_new_route_snapshot,
    p_user_id
  );

  UPDATE trips
  SET status = 'planned',
      route_version = v_new_route_version,
      updated_by = p_user_id,
      updated_at = NOW()
  WHERE id = p_trip_id;

  INSERT INTO trip_planning_returns (
    trip_id,
    previous_route_version,
    new_route_version,
    reason,
    returned_by,
    operation_key
  )
  VALUES (
    p_trip_id,
    v_trip.route_version,
    v_new_route_version,
    TRIM(p_reason),
    p_user_id,
    p_operation_key
  )
  RETURNING id INTO v_return_id;

  RETURN v_return_id;
END;
$$;