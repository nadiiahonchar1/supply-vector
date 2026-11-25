-- =========================================================
-- 1. EVENT TYPES
-- =========================================================

CREATE TABLE trip_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  reported_by UUID NOT NULL REFERENCES users(id),

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
      comment IS NULL OR LENGTH(comment) <= 2000
    )
);

CREATE INDEX trip_incidents_trip_idx
  ON trip_incidents(trip_id, occurred_at DESC);

CREATE INDEX trip_incidents_reporter_idx
  ON trip_incidents(reported_by, occurred_at DESC);


-- =========================================================
-- 2. MESSAGE IMMUNITY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_incident_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Зареєстроване повідомлення про подію не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER trip_incidents_immutable
BEFORE UPDATE OR DELETE
ON trip_incidents
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_incident_mutation();


-- =========================================================
-- 3. REGISTRATION OF A NOTIFICATION
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
  v_incident_id UUID;
  v_trip_status TEXT;
  v_is_driver BOOLEAN;
BEGIN
  IF p_trip_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION
      'Необхідно вказати рейс та автора повідомлення';
  END IF;

  IF p_incident_type NOT IN (
    'road_obstacle',
    'vehicle_breakdown',
    'accident',
    'delay',
    'route_condition',
    'other'
  ) THEN
    RAISE EXCEPTION 'Невідомий тип події';
  END IF;

  IF p_description IS NULL
     OR LENGTH(TRIM(p_description)) = 0
     OR LENGTH(p_description) > 2000 THEN
    RAISE EXCEPTION
      'Опис події обов’язковий (до 2000 символів)';
  END IF;

  IF p_comment IS NOT NULL
     AND LENGTH(p_comment) > 2000 THEN
    RAISE EXCEPTION
      'Коментар не може перевищувати 2000 символів';
  END IF;

  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip_status NOT IN ('ready', 'in_transit', 'delivered') THEN
    RAISE EXCEPTION
      'Повідомлення про подію можна зареєструвати лише для підготовленого або розпочатого рейсу';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM trips t
    JOIN employees e ON e.id = t.driver_id
    WHERE t.id = p_trip_id
      AND e.user_id = p_user_id
      AND e.is_active = TRUE
  )
  INTO v_is_driver;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION
      'Неактивний користувач не може реєструвати події';
  END IF;

  IF NOT v_is_driver
     AND NOT EXISTS (
       SELECT 1
       FROM user_roles ur
       JOIN role_permissions rp ON rp.role_id = ur.role_id
       JOIN permissions p ON p.id = rp.permission_id
       WHERE ur.user_id = p_user_id
         AND p.code = 'trip_incident_report'
     ) THEN
    RAISE EXCEPTION
      'Недостатньо прав для реєстрації події цього рейсу';
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
    p_comment,
    COALESCE(p_occurred_at, NOW())
  )
  RETURNING id INTO v_incident_id;

  RETURN v_incident_id;
END;
$$;


-- =========================================================
-- 4. PERMISSION
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
  'trip_incident_report',
  'Реєстрація повідомлень про події під час рейсу'
)
ON CONFLICT (code) DO NOTHING;