-- =========================================================
-- 1. AUTHORIZATION TO RETURN A FLIGHT TO PLANNING
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'trip_return_to_planned',
  'Повернення рейсу до планування'
)
ON CONFLICT (code) DO NOTHING;


-- =========================================================
-- 2. FLIGHT RETURN LOG
-- =========================================================

CREATE TABLE trip_planning_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  previous_route_version INTEGER NOT NULL,
  new_route_version INTEGER NOT NULL,

  reason TEXT NOT NULL,

  returned_by UUID NOT NULL REFERENCES users(id),

  operation_key UUID NOT NULL UNIQUE,

  returned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT trip_planning_returns_reason_check
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000),

  CONSTRAINT trip_planning_returns_version_check
    CHECK (new_route_version > previous_route_version)
);

CREATE INDEX trip_planning_returns_trip_idx
  ON trip_planning_returns(trip_id, returned_at DESC);


-- =========================================================
-- 3. JOURNAL PROTECTION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_planning_return_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію повернення рейсів не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER trip_planning_returns_immutable
BEFORE UPDATE OR DELETE
ON trip_planning_returns
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_planning_return_mutation();


-- =========================================================
-- 4. CHECKING YOUR RIGHT TO REFUND YOUR FLIGHT
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
    JOIN user_roles ur ON ur.user_id = u.id
    JOIN role_permissions rp ON rp.role_id = ur.role_id
    JOIN permissions p ON p.id = rp.permission_id
    WHERE u.id = p_user_id
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
      AND p.code = 'trip_return_to_planned'
  );
$$;


-- =========================================================
-- 5. RETURN OF A FLIGHT TO THE SCHEDULE
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
  v_return_id UUID;
  v_existing_id UUID;
  v_new_route_version INTEGER;
  v_new_route_snapshot JSONB;
  v_route_version_id UUID;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL
     OR LENGTH(TRIM(p_reason)) > 2000 THEN
    RAISE EXCEPTION
      'Необхідно вказати причину повернення до планування';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM trip_planning_returns
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  IF NOT user_can_return_trip_to_planned(p_user_id) THEN
    RAISE EXCEPTION
      'Користувач не має права повертати рейс до планування';
  END IF;

  SELECT *
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip.status <> 'ready' THEN
    RAISE EXCEPTION
      'Повернути до планування можна лише рейс зі статусом ready';
  END IF;

  IF v_trip.actual_departure_at IS NOT NULL THEN
    RAISE EXCEPTION
      'Рейс уже виїхав. Повернення до планування неможливе';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM trip_stops
    WHERE trip_id = p_trip_id
      AND actual_departure_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'Є фактично зафіксований виїзд із зупинки';
  END IF;

  PERFORM set_config(
    'app.current_user_id',
    p_user_id::TEXT,
    TRUE
  );

  UPDATE trips
  SET status = 'planned',
      updated_at = NOW()
  WHERE id = p_trip_id;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_new_route_version
  FROM trip_route_versions
  WHERE trip_id = p_trip_id;

  SELECT COALESCE(
    JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'stop_id', ts.id,
        'sequence', ts.sequence,
        'storage_point_id', ts.storage_point_id
      )
      ORDER BY ts.sequence
    ),
    '[]'::JSONB
  )
  INTO v_new_route_snapshot
  FROM trip_stops ts
  WHERE ts.trip_id = p_trip_id;

  IF JSONB_ARRAY_LENGTH(v_new_route_snapshot) < 2 THEN
    RAISE EXCEPTION
      'Маршрут повинен містити щонайменше дві точки';
  END IF;

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
  )
  RETURNING id INTO v_route_version_id;

  UPDATE trips
  SET route_version = v_new_route_version,
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