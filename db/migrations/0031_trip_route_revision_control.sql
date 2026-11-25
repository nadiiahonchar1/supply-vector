-- =========================================================
-- 1. LOG OF ACTUAL DEVIATIONS FROM THE ROUTE
-- =========================================================

CREATE TABLE trip_route_deviations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  reported_by UUID NOT NULL REFERENCES users(id),

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
      ended_at IS NULL OR ended_at >= started_at
    )
);

CREATE INDEX trip_route_deviations_trip_idx
  ON trip_route_deviations(trip_id, started_at DESC);


-- =========================================================
-- 2. ACTUAL ROUTE SECTIONS
-- =========================================================

CREATE TABLE trip_actual_route_segments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  deviation_id UUID REFERENCES trip_route_deviations(id),

  sequence INTEGER NOT NULL CHECK (sequence > 0),

  started_at TIMESTAMPTZ NOT NULL,

  ended_at TIMESTAMPTZ,

  start_latitude NUMERIC(9,6),
  start_longitude NUMERIC(9,6),

  end_latitude NUMERIC(9,6),
  end_longitude NUMERIC(9,6),

  description TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT actual_route_segment_time_check
    CHECK (
      ended_at IS NULL OR ended_at >= started_at
    ),

  CONSTRAINT actual_route_start_coordinates_check
    CHECK (
      (start_latitude IS NULL AND start_longitude IS NULL)
      OR (
        start_latitude BETWEEN -90 AND 90
        AND start_longitude BETWEEN -180 AND 180
      )
    ),

  CONSTRAINT actual_route_end_coordinates_check
    CHECK (
      (end_latitude IS NULL AND end_longitude IS NULL)
      OR (
        end_latitude BETWEEN -90 AND 90
        AND end_longitude BETWEEN -180 AND 180
      )
    ),

  UNIQUE (trip_id, sequence)
);


-- =========================================================
-- 3. ІСТОРІЯ ЗМІН МАЙБУТНЬОЇ ЧАСТИНИ МАРШРУТУ
-- =========================================================

CREATE TABLE trip_route_revision_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  previous_version INTEGER NOT NULL,

  new_version INTEGER NOT NULL,

  reason TEXT NOT NULL,

  changed_by UUID NOT NULL REFERENCES users(id),

  operation_key UUID NOT NULL UNIQUE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT route_revision_version_check
    CHECK (new_version > previous_version),

  CONSTRAINT route_revision_reason_check
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000)
);

CREATE INDEX trip_route_revision_events_trip_idx
  ON trip_route_revision_events(trip_id, created_at DESC);


-- =========================================================
-- 4. HISTORY OF CHANGES TO THE FUTURE SECTION OF THE ROUTE
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_route_revision_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію змін маршруту не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER trip_route_revision_events_immutable
BEFORE UPDATE OR DELETE
ON trip_route_revision_events
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_revision_event_mutation();


-- =========================================================
-- 5. PROHIBITION ON CHANGING COMPLETED STOPS
-- =========================================================

CREATE OR REPLACE FUNCTION protect_completed_trip_stops()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.actual_arrival_at IS NOT NULL
       OR OLD.actual_departure_at IS NOT NULL THEN
      RAISE EXCEPTION
        'Виконану зупинку не можна видаляти';
    END IF;

    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN

    IF OLD.actual_arrival_at IS NOT NULL
       OR OLD.actual_departure_at IS NOT NULL THEN

      IF NEW.trip_id IS DISTINCT FROM OLD.trip_id
         OR NEW.sequence IS DISTINCT FROM OLD.sequence
         OR NEW.storage_point_id IS DISTINCT FROM OLD.storage_point_id
         OR NEW.planned_arrival_at IS DISTINCT FROM OLD.planned_arrival_at
         OR NEW.planned_departure_at IS DISTINCT FROM OLD.planned_departure_at THEN
        RAISE EXCEPTION
          'Планові дані виконаної зупинки не можна змінювати';
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
-- 6. CHECKING THE POSSIBILITY OF CHANGING THE ROUTE
-- =========================================================

CREATE OR REPLACE FUNCTION assert_trip_route_can_be_revised(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status
  INTO v_status
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_status NOT IN ('planned', 'ready') THEN
    RAISE EXCEPTION
      'Змінювати маршрут можна лише до фактичного відправлення';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM trips
    WHERE id = p_trip_id
      AND actual_departure_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'Після фактичного відправлення плановий маршрут змінювати не можна';
  END IF;
END;
$$;


-- =========================================================
-- 7. VERIFICATION THAT COMPLETED STOPS ARE SAVED
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
  FOR v_stop IN
    SELECT
      id,
      sequence,
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
    FROM JSONB_ARRAY_ELEMENTS(p_new_snapshot) element
    WHERE element->>'stop_id' = v_stop.id::TEXT;

    IF v_snapshot_stop IS NULL THEN
      RAISE EXCEPTION
        'Нова версія маршруту не містить виконану зупинку';
    END IF;

    IF (v_snapshot_stop->>'sequence')::INTEGER
       <> v_stop.sequence
       OR (v_snapshot_stop->>'storage_point_id')::UUID
       <> v_stop.storage_point_id THEN
      RAISE EXCEPTION
        'Виконану зупинку не можна переміщувати або змінювати';
    END IF;

  END LOOP;
END;
$$;


-- =========================================================
-- 8. VERIFICATION OF THE ACTUAL ROUTE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_actual_route_segment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip_status TEXT;
BEGIN
  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = NEW.trip_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip_status NOT IN ('in_transit', 'delivered') THEN
    RAISE EXCEPTION
      'Фактичний маршрут можна фіксувати лише після відправлення';
  END IF;

  IF NEW.deviation_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM trip_route_deviations
       WHERE id = NEW.deviation_id
         AND trip_id = NEW.trip_id
     ) THEN
    RAISE EXCEPTION
      'Відхилення не належить цьому рейсу';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER actual_route_segment_validation
BEFORE INSERT
ON trip_actual_route_segments
FOR EACH ROW
EXECUTE FUNCTION validate_actual_route_segment();