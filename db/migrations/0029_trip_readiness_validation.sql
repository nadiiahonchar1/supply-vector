-- =========================================================
-- 1. DRIVER'S LICENSE CATEGORIES REQUIRED FOR VEHICLES
-- =========================================================

CREATE TABLE vehicle_required_license_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  vehicle_id UUID NOT NULL
    REFERENCES vehicles(id),

  license_category_id UUID NOT NULL
    REFERENCES driver_license_categories(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (vehicle_id, license_category_id)
);


-- =========================================================
-- 2. ROUTE VERSION HISTORY
-- =========================================================

CREATE TABLE trip_route_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  version_number INTEGER NOT NULL CHECK (version_number > 0),

  reason TEXT,

  route_snapshot JSONB NOT NULL,

  created_by UUID NOT NULL REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (trip_id, version_number)
);


-- =========================================================
-- 3. ROUTE APPROVAL
-- =========================================================

CREATE TABLE trip_route_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  trip_id UUID NOT NULL REFERENCES trips(id),

  route_version INTEGER NOT NULL CHECK (route_version > 0),

  approved_by UUID NOT NULL REFERENCES users(id),

  comment TEXT,

  approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  operation_key UUID NOT NULL UNIQUE
);

CREATE INDEX trip_route_approvals_trip_idx
  ON trip_route_approvals(trip_id, route_version);


-- =========================================================
-- 4. THE IMMUTABILITY OF ROUTE HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_route_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію версій та погоджень маршруту не можна змінювати';
END;
$$;

CREATE TRIGGER trip_route_versions_immutable
BEFORE UPDATE OR DELETE
ON trip_route_versions
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_history_mutation();

CREATE TRIGGER trip_route_approvals_immutable
BEFORE UPDATE OR DELETE
ON trip_route_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_history_mutation();


-- =========================================================
-- 5. GENERATING A ROUTE SNAPSHOT
-- =========================================================

CREATE OR REPLACE FUNCTION create_trip_route_version(
  p_trip_id UUID,
  p_user_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
  v_snapshot JSONB;
  v_version INTEGER;
  v_id UUID;
BEGIN
  SELECT *
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip.status <> 'planned' THEN
    RAISE EXCEPTION
      'Змінювати маршрут можна лише для рейсу зі статусом planned';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION
      'Для створення версії маршруту необхідно вказати причину';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_version
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
  INTO v_snapshot
  FROM trip_stops ts
  WHERE ts.trip_id = p_trip_id;

  IF JSONB_ARRAY_LENGTH(v_snapshot) < 2 THEN
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
    v_version,
    TRIM(p_reason),
    v_snapshot,
    p_user_id
  )
  RETURNING id INTO v_id;

  UPDATE trips
  SET route_version = v_version,
      updated_at = NOW()
  WHERE id = p_trip_id;

  RETURN v_id;
END;
$$;


-- =========================================================
-- 6. APPROVAL OF THE CURRENT VERSION OF THE ROUTE
-- =========================================================

CREATE OR REPLACE FUNCTION approve_trip_route(
  p_trip_id UUID,
  p_user_id UUID,
  p_operation_key UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
  v_approval_id UUID;
  v_existing_id UUID;
BEGIN
  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM trip_route_approvals
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  SELECT *
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip.status <> 'planned' THEN
    RAISE EXCEPTION
      'Погодити маршрут можна лише для запланованого рейсу';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM trip_route_versions
    WHERE trip_id = p_trip_id
      AND version_number = v_trip.route_version
  ) THEN
    RAISE EXCEPTION
      'Поточна версія маршруту ще не сформована';
  END IF;

  INSERT INTO trip_route_approvals (
    trip_id,
    route_version,
    approved_by,
    comment,
    operation_key
  )
  VALUES (
    p_trip_id,
    v_trip.route_version,
    p_user_id,
    p_comment,
    p_operation_key
  )
  RETURNING id INTO v_approval_id;

  RETURN v_approval_id;
END;
$$;


-- =========================================================
-- 7. DRIVER AND VEHICLE CHECK
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_driver_and_vehicle(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
BEGIN
  SELECT
    t.*,
    v.status AS vehicle_status,
    e.is_active AS driver_active
  INTO v_trip
  FROM trips t
  JOIN vehicles v ON v.id = t.vehicle_id
  JOIN employees e ON e.id = t.driver_id
  WHERE t.id = p_trip_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Не знайдено рейс, автомобіль або водія';
  END IF;

  IF v_trip.vehicle_status <> 'active' THEN
    RAISE EXCEPTION
      'Автомобіль не перебуває в активному стані';
  END IF;

  IF NOT v_trip.driver_active THEN
    RAISE EXCEPTION
      'Водій неактивний';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM employee_vehicle_authorizations eva
    WHERE eva.employee_id = v_trip.driver_id
      AND eva.vehicle_id = v_trip.vehicle_id
      AND eva.valid_from <= CURRENT_DATE
      AND (
        eva.valid_until IS NULL
        OR eva.valid_until >= CURRENT_DATE
      )
  ) THEN
    RAISE EXCEPTION
      'Водій не має чинного дозволу на цей автомобіль';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM vehicle_required_license_categories vrl
    WHERE vrl.vehicle_id = v_trip.vehicle_id
      AND NOT EXISTS (
        SELECT 1
        FROM employee_driver_licenses edl
        WHERE edl.employee_id = v_trip.driver_id
          AND edl.license_category_id = vrl.license_category_id
          AND edl.valid_from <= CURRENT_DATE
          AND (
            edl.valid_until IS NULL
            OR edl.valid_until >= CURRENT_DATE
          )
      )
  ) THEN
    RAISE EXCEPTION
      'У водія відсутня необхідна чинна категорія посвідчення';
  END IF;
END;
$$;


-- =========================================================
-- 8. VERIFICATION OF ROUTE COMPLIANCE WITH DEPARTURES
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_shipment_routes(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_source_sequence INTEGER;
  v_destination_sequence INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM shipments
    WHERE trip_id = p_trip_id
  ) THEN
    RAISE EXCEPTION
      'До рейсу не призначено жодного відправлення';
  END IF;

  FOR v_shipment IN
    SELECT *
    FROM shipments
    WHERE trip_id = p_trip_id
  LOOP
    SELECT sequence
    INTO v_source_sequence
    FROM trip_stops
    WHERE trip_id = p_trip_id
      AND storage_point_id = v_shipment.source_storage_point_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'У маршруті відсутня точка відправлення';
    END IF;

    SELECT sequence
    INTO v_destination_sequence
    FROM trip_stops
    WHERE trip_id = p_trip_id
      AND storage_point_id = v_shipment.destination_storage_point_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'У маршруті відсутня точка призначення';
    END IF;

    IF v_source_sequence >= v_destination_sequence THEN
      RAISE EXCEPTION
        'Точка відправлення повинна передувати точці призначення';
    END IF;
  END LOOP;
END;
$$;


-- =========================================================
-- 9. CAPACITY CHECK AT EACH SECTION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_leg_capacity(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
  v_leg RECORD;

  v_weight NUMERIC;
  v_volume NUMERIC;
BEGIN
  SELECT
    t.vehicle_id,
    v.max_weight_kg,
    v.max_volume_m3
  INTO v_trip
  FROM trips t
  JOIN vehicles v ON v.id = t.vehicle_id
  WHERE t.id = p_trip_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс або автомобіль не знайдено';
  END IF;

  IF v_trip.max_weight_kg IS NULL
     OR v_trip.max_volume_m3 IS NULL THEN
    RAISE EXCEPTION
      'Для автомобіля необхідно вказати максимальну вагу та об’єм';
  END IF;

  FOR v_leg IN
    SELECT
      a.sequence AS leg_start,
      b.sequence AS leg_end
    FROM trip_stops a
    JOIN trip_stops b
      ON b.trip_id = a.trip_id
     AND b.sequence = a.sequence + 1
    WHERE a.trip_id = p_trip_id
    ORDER BY a.sequence
  LOOP
    
    SELECT
      COALESCE(SUM(
        (
          SELECT SUM(slm.quantity)
          FROM shipment_loading_movements slm
          JOIN shipment_items si
            ON si.id = slm.shipment_item_id
          WHERE si.shipment_id = s.id
        ) * p.weight_kg
      ), 0),

      COALESCE(SUM(
        (
          SELECT SUM(slm.quantity)
          FROM shipment_loading_movements slm
          JOIN shipment_items si
            ON si.id = slm.shipment_item_id
          WHERE si.shipment_id = s.id
        ) * p.volume_m3
      ), 0)

    INTO v_weight, v_volume

    FROM shipments s
    JOIN shipment_items si
      ON si.shipment_id = s.id
    JOIN products p
      ON p.id = si.product_id
    JOIN trip_stops source_stop
      ON source_stop.trip_id = p_trip_id
     AND source_stop.storage_point_id = s.source_storage_point_id
    JOIN trip_stops destination_stop
      ON destination_stop.trip_id = p_trip_id
     AND destination_stop.storage_point_id = s.destination_storage_point_id

    WHERE s.trip_id = p_trip_id
      AND source_stop.sequence <= v_leg.leg_start
      AND destination_stop.sequence > v_leg.leg_start;

    IF EXISTS (
      SELECT 1
      FROM shipments s
      JOIN shipment_items si ON si.shipment_id = s.id
      JOIN products p ON p.id = si.product_id
      JOIN trip_stops source_stop
        ON source_stop.trip_id = p_trip_id
       AND source_stop.storage_point_id = s.source_storage_point_id
      JOIN trip_stops destination_stop
        ON destination_stop.trip_id = p_trip_id
       AND destination_stop.storage_point_id = s.destination_storage_point_id
      WHERE s.trip_id = p_trip_id
        AND source_stop.sequence <= v_leg.leg_start
        AND destination_stop.sequence > v_leg.leg_start
        AND (
          p.weight_kg IS NULL
          OR p.volume_m3 IS NULL
        )
    ) THEN
      RAISE EXCEPTION
        'Неможливо перевірити місткість: для товару не вказано вагу або об’єм';
    END IF;

    IF v_weight > v_trip.max_weight_kg THEN
      RAISE EXCEPTION
        'Перевищено допустиму вагу автомобіля на ділянці маршруту %',
        v_leg.leg_start;
    END IF;

    IF v_volume > v_trip.max_volume_m3 THEN
      RAISE EXCEPTION
        'Перевищено допустимий об’єм автомобіля на ділянці маршруту %',
        v_leg.leg_start;
    END IF;

  END LOOP;
END;
$$;


-- =========================================================
-- 10. SINGLE FLIGHT READINESS CHECK
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_readiness(
  p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip RECORD;
BEGIN
  SELECT *
  INTO v_trip
  FROM trips
  WHERE id = p_trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рейс не знайдено';
  END IF;

  IF v_trip.status <> 'planned' THEN
    RAISE EXCEPTION
      'Перевіряти готовність можна лише для planned рейсу';
  END IF;

  PERFORM validate_trip_driver_and_vehicle(p_trip_id);

  PERFORM validate_trip_shipment_routes(p_trip_id);

  PERFORM validate_trip_leg_capacity(p_trip_id);

  IF NOT EXISTS (
    SELECT 1
    FROM trip_route_approvals
    WHERE trip_id = p_trip_id
      AND route_version = v_trip.route_version
  ) THEN
    RAISE EXCEPTION
      'Поточна версія маршруту не погоджена';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM trip_stops
    WHERE trip_id = p_trip_id
    GROUP BY sequence
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Маршрут містить повторювані номери зупинок';
  END IF;
END;
$$;


-- =========================================================
-- 11. PROTECTION OF FLIGHT TRANSITION TO 'READY'
-- =========================================================

CREATE OR REPLACE FUNCTION enforce_trip_readiness()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'ready'
     AND OLD.status IS DISTINCT FROM NEW.status THEN

    PERFORM validate_trip_readiness(NEW.id);

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trip_readiness_guard
BEFORE UPDATE OF status
ON trips
FOR EACH ROW
EXECUTE FUNCTION enforce_trip_readiness();