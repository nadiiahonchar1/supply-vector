-- =========================================================
-- 1. ACTUAL ROUTE DEVIATIONS
-- =========================================================

CREATE TABLE trip_route_deviations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL
    REFERENCES trips(id) ON DELETE RESTRICT,

  reported_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  reason TEXT NOT NULL,

  description TEXT,

  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  ended_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT trip_route_deviations_reason_check
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 500),

  CONSTRAINT trip_route_deviations_description_check
    CHECK (
      description IS NULL
      OR LENGTH(description) <= 2000
    ),

  CONSTRAINT trip_route_deviations_time_check
    CHECK (
      ended_at IS NULL
      OR ended_at >= started_at
    )
);

CREATE INDEX trip_route_deviations_trip_idx
  ON trip_route_deviations(trip_id, started_at DESC);


-- =========================================================
-- 2. ACTUAL ROUTE SEGMENTS
-- =========================================================

CREATE TABLE trip_actual_route_segments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL
    REFERENCES trips(id) ON DELETE RESTRICT,

  deviation_id UUID,

  sequence INTEGER NOT NULL
    CHECK (sequence > 0),

  started_at TIMESTAMPTZ NOT NULL,

  ended_at TIMESTAMPTZ,

  start_latitude NUMERIC(9, 6),
  start_longitude NUMERIC(9, 6),

  end_latitude NUMERIC(9, 6),
  end_longitude NUMERIC(9, 6),

  description TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT actual_route_segment_time_check
    CHECK (
      ended_at IS NULL
      OR ended_at >= started_at
    ),

  CONSTRAINT actual_route_start_coordinates_check
    CHECK (
      (
        start_latitude IS NULL
        AND start_longitude IS NULL
      )
      OR (
        start_latitude BETWEEN -90 AND 90
        AND start_longitude BETWEEN -180 AND 180
      )
    ),

  CONSTRAINT actual_route_end_coordinates_check
    CHECK (
      (
        end_latitude IS NULL
        AND end_longitude IS NULL
      )
      OR (
        end_latitude BETWEEN -90 AND 90
        AND end_longitude BETWEEN -180 AND 180
      )
    ),

  CONSTRAINT actual_route_segment_deviation_fk
    FOREIGN KEY (deviation_id, trip_id)
    REFERENCES trip_route_deviations(id, trip_id)
    ON DELETE RESTRICT,

  CONSTRAINT actual_route_segment_sequence_unique
    UNIQUE (trip_id, sequence)
);

ALTER TABLE trip_route_deviations
  ADD CONSTRAINT trip_route_deviations_id_trip_unique
  UNIQUE (id, trip_id);


-- =========================================================
-- 3. ROUTE REVISION HISTORY
-- =========================================================

CREATE TABLE trip_route_revision_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL
    REFERENCES trips(id) ON DELETE RESTRICT,

  previous_version INTEGER NOT NULL
    CHECK (previous_version > 0),

  new_version INTEGER NOT NULL
    CHECK (new_version > previous_version),

  reason TEXT NOT NULL,

  changed_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  operation_key UUID NOT NULL UNIQUE,

  previous_route_snapshot JSONB NOT NULL
    CHECK (JSONB_TYPEOF(previous_route_snapshot) = 'array'),

  new_route_snapshot JSONB NOT NULL
    CHECK (JSONB_TYPEOF(new_route_snapshot) = 'array'),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT route_revision_reason_check
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000)
);

CREATE INDEX trip_route_revision_events_trip_idx
  ON trip_route_revision_events(trip_id, created_at DESC);


-- =========================================================
-- 4. IMMUTABLE ROUTE REVISION HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_route_revision_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'trip_route_revision_history_is_immutable';
END;
$$;

CREATE TRIGGER trip_route_revision_events_immutable
BEFORE UPDATE OR DELETE
ON trip_route_revision_events
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_revision_event_mutation();


-- =========================================================
-- 5. PROTECT COMPLETED TRIP STOPS
-- =========================================================

CREATE OR REPLACE FUNCTION protect_completed_trip_stops()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.actual_arrival_at IS NOT NULL
       OR OLD.actual_departure_at IS NOT NULL THEN
      RAISE EXCEPTION 'completed_trip_stop_cannot_be_deleted';
    END IF;

    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN   
    IF OLD.actual_arrival_at IS NOT NULL
       AND NEW.actual_arrival_at IS DISTINCT FROM OLD.actual_arrival_at THEN
      RAISE EXCEPTION 'actual_arrival_timestamp_is_immutable';
    END IF;

    IF OLD.actual_departure_at IS NOT NULL
       AND NEW.actual_departure_at IS DISTINCT FROM OLD.actual_departure_at THEN
      RAISE EXCEPTION 'actual_departure_timestamp_is_immutable';
    END IF;
   
    IF OLD.actual_arrival_at IS NOT NULL
       OR OLD.actual_departure_at IS NOT NULL THEN

      IF NEW.trip_id IS DISTINCT FROM OLD.trip_id
         OR NEW.sequence_number IS DISTINCT FROM OLD.sequence_number
         OR NEW.storage_point_id IS DISTINCT FROM OLD.storage_point_id
         OR NEW.planned_arrival_at IS DISTINCT FROM OLD.planned_arrival_at
         OR NEW.planned_departure_at IS DISTINCT FROM OLD.planned_departure_at THEN
        RAISE EXCEPTION 'completed_trip_stop_route_data_is_immutable';
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trip_completed_stop_guard
BEFORE UPDATE OR DELETE
ON trip_stops
FOR EACH ROW
EXECUTE FUNCTION protect_completed_trip_stops();


-- =========================================================
-- 6. CHECK WHETHER A TRIP ROUTE CAN BE REVISED
-- =========================================================

CREATE OR REPLACE FUNCTION assert_trip_route_can_be_revised(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
BEGIN
  SELECT status, actual_departure_at
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trip_not_found';
  END IF;

  IF v_trip.status IN ('planned', 'ready') THEN
    IF v_trip.actual_departure_at IS NOT NULL THEN
      RAISE EXCEPTION 'trip_departure_already_recorded';
    END IF;

    RETURN;
  END IF;

  IF v_trip.status = 'in_transit' THEN
    IF v_trip.actual_departure_at IS NULL THEN
      RAISE EXCEPTION 'trip_departure_not_recorded';
    END IF;

    RETURN;
  END IF;

  RAISE EXCEPTION 'trip_route_cannot_be_revised_in_current_status';
END;
$$;


-- =========================================================
-- 7. PRESERVE COMPLETED STOPS IN A NEW ROUTE SNAPSHOT
-- =========================================================

CREATE OR REPLACE FUNCTION validate_completed_stops_preserved(
  p_trip_id UUID,
  p_new_snapshot JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_stop RECORD;
  v_snapshot_stop JSONB;
BEGIN
  IF p_new_snapshot IS NULL
     OR JSONB_TYPEOF(p_new_snapshot) <> 'array' THEN
    RAISE EXCEPTION 'invalid_route_snapshot';
  END IF;

  FOR v_stop IN
    SELECT
      id,
      sequence_number,
      storage_point_id
    FROM trip_stops
    WHERE trip_id = p_trip_id
      AND (
        actual_arrival_at IS NOT NULL
        OR actual_departure_at IS NOT NULL
      )
  LOOP
    SELECT element
    INTO v_snapshot_stop
    FROM JSONB_ARRAY_ELEMENTS(p_new_snapshot) AS element
    WHERE element->>'stop_id' = v_stop.id::TEXT;

    IF v_snapshot_stop IS NULL THEN
      RAISE EXCEPTION 'completed_trip_stop_missing_from_new_route';
    END IF;

    IF (v_snapshot_stop->>'sequence')::INTEGER
       IS DISTINCT FROM v_stop.sequence_number
       OR (v_snapshot_stop->>'storage_point_id')::UUID
       IS DISTINCT FROM v_stop.storage_point_id THEN
      RAISE EXCEPTION 'completed_trip_stop_changed_in_new_route';
    END IF;
  END LOOP;
END;
$$;


-- =========================================================
-- 8. VALIDATE ACTUAL ROUTE SEGMENTS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_actual_route_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip_status TEXT;
  v_actual_departure_at TIMESTAMPTZ;
BEGIN
  SELECT status, actual_departure_at
  INTO v_trip_status, v_actual_departure_at
  FROM trips
  WHERE id = NEW.trip_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'trip_not_found';
  END IF;

  IF v_trip_status NOT IN ('in_transit', 'delivered') THEN
    RAISE EXCEPTION 'actual_route_requires_departed_trip';
  END IF;

  IF v_actual_departure_at IS NULL THEN
    RAISE EXCEPTION 'trip_departure_not_recorded';
  END IF;

  IF NEW.started_at < v_actual_departure_at THEN
    RAISE EXCEPTION 'actual_route_segment_precedes_trip_departure';
  END IF;

  IF NEW.deviation_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM trip_route_deviations
       WHERE id = NEW.deviation_id
         AND trip_id = NEW.trip_id
     ) THEN
    RAISE EXCEPTION 'route_deviation_does_not_belong_to_trip';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER actual_route_segment_validation
BEFORE INSERT OR UPDATE
ON trip_actual_route_segments
FOR EACH ROW
EXECUTE FUNCTION validate_actual_route_segment();


-- =========================================================
-- 9. IMMUTABLE ACTUAL ROUTE SEGMENTS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_actual_route_segment_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'actual_route_segment_history_is_immutable';
END;
$$;

CREATE TRIGGER actual_route_segments_immutable
BEFORE UPDATE OR DELETE
ON trip_actual_route_segments
FOR EACH ROW
EXECUTE FUNCTION prevent_actual_route_segment_mutation();


-- =========================================================
-- 10. VALIDATE ROUTE DEVIATION CLOSURE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_route_deviation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.trip_id IS DISTINCT FROM OLD.trip_id
     OR NEW.reported_by IS DISTINCT FROM OLD.reported_by
     OR NEW.reason IS DISTINCT FROM OLD.reason
     OR NEW.description IS DISTINCT FROM OLD.description
     OR NEW.started_at IS DISTINCT FROM OLD.started_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'route_deviation_details_are_immutable';
  END IF;

  IF OLD.ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'route_deviation_already_closed';
  END IF;

  IF NEW.ended_at IS NULL THEN
    RAISE EXCEPTION 'route_deviation_update_must_set_end_time';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trip_route_deviation_update_guard
BEFORE UPDATE
ON trip_route_deviations
FOR EACH ROW
EXECUTE FUNCTION validate_trip_route_deviation_update();

CREATE OR REPLACE FUNCTION prevent_trip_route_deviation_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'route_deviation_history_is_immutable';
END;
$$;

CREATE TRIGGER trip_route_deviations_immutable
BEFORE DELETE
ON trip_route_deviations
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_deviation_delete();