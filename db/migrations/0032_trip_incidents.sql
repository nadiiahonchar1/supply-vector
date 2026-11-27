-- =========================================================
-- 1. TRIP INCIDENTS
-- =========================================================

CREATE TABLE trip_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL
    REFERENCES trips(id) ON DELETE RESTRICT,

  reported_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  incident_type TEXT NOT NULL,

  description TEXT NOT NULL,

  comment TEXT,

  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT trip_incidents_type_check
    CHECK (
      incident_type IN (
        'road_obstacle',
        'vehicle_breakdown',
        'accident',
        'delay',
        'route_condition',
        'other'
      )
    ),

  CONSTRAINT trip_incidents_description_check
    CHECK (
      LENGTH(TRIM(description)) BETWEEN 1 AND 2000
    ),

  CONSTRAINT trip_incidents_comment_check
    CHECK (
      comment IS NULL
      OR LENGTH(comment) <= 2000
    )
);

CREATE INDEX trip_incidents_trip_idx
  ON trip_incidents(trip_id, occurred_at DESC);

CREATE INDEX trip_incidents_reporter_idx
  ON trip_incidents(reported_by, occurred_at DESC);

CREATE INDEX trip_incidents_type_idx
  ON trip_incidents(incident_type, occurred_at DESC);


-- =========================================================
-- 2. INCIDENT REPORTING PERMISSION
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'trip_incident_report',
  'Report trip incidents'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 3. IMMUTABLE INCIDENT HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_incident_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'trip_incident_history_is_immutable';
END;
$$;

CREATE TRIGGER trip_incidents_immutable
BEFORE UPDATE OR DELETE
ON trip_incidents
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_incident_mutation();


-- =========================================================
-- 4. CHECK INCIDENT REPORTING AUTHORIZATION
-- =========================================================

CREATE OR REPLACE FUNCTION user_can_report_trip_incident(
  p_user_id UUID,
  p_trip_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM trips t
    JOIN employees e
      ON e.id = t.driver_id
    JOIN users u
      ON u.id = e.user_id
    WHERE t.id = p_trip_id
      AND u.id = p_user_id
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
      AND e.is_active = TRUE
  )
  OR EXISTS (
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
      AND p.code = 'trip_incident_report'
  );
$$;


-- =========================================================
-- 5. REGISTER A TRIP INCIDENT
-- =========================================================

CREATE OR REPLACE FUNCTION report_trip_incident(
  p_trip_id UUID,
  p_user_id UUID,
  p_incident_type TEXT,
  p_description TEXT,
  p_comment TEXT DEFAULT NULL,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
  v_incident_id UUID;
BEGIN
  IF p_trip_id IS NULL
     OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'required_parameter_is_missing';
  END IF;

  IF p_incident_type IS NULL
     OR p_incident_type NOT IN (
       'road_obstacle',
       'vehicle_breakdown',
       'accident',
       'delay',
       'route_condition',
       'other'
     ) THEN
    RAISE EXCEPTION 'invalid_trip_incident_type';
  END IF;

  IF p_description IS NULL
     OR LENGTH(TRIM(p_description)) = 0
     OR LENGTH(p_description) > 2000 THEN
    RAISE EXCEPTION 'invalid_trip_incident_description';
  END IF;

  IF p_comment IS NOT NULL
     AND LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION 'trip_incident_comment_too_long';
  END IF;

  IF p_occurred_at IS NULL
     OR p_occurred_at > NOW() THEN
    RAISE EXCEPTION 'invalid_trip_incident_timestamp';
  END IF;

  SELECT
    id,
    status,
    actual_departure_at
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trip_not_found';
  END IF;

  IF v_trip.status NOT IN (
    'ready',
    'in_transit',
    'delivered'
  ) THEN
    RAISE EXCEPTION 'trip_incident_not_allowed_in_current_status';
  END IF;

  IF NOT user_can_report_trip_incident(
    p_user_id,
    p_trip_id
  ) THEN
    RAISE EXCEPTION 'permission_denied';
  END IF;

  IF v_trip.status IN ('in_transit', 'delivered')
     AND v_trip.actual_departure_at IS NULL THEN
    RAISE EXCEPTION 'trip_departure_not_recorded';
  END IF;

  INSERT INTO trip_incidents (
    trip_id,
    reported_by,
    incident_type,
    description,
    comment,
    occurred_at
  )
  VALUES (
    p_trip_id,
    p_user_id,
    p_incident_type,
    TRIM(p_description),
    NULLIF(TRIM(p_comment), ''),
    p_occurred_at
  )
  RETURNING id INTO v_incident_id;

  RETURN v_incident_id;
END;
$$;