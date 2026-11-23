-- =========================================================
-- 1. VEHICLES
-- =========================================================

CREATE TABLE vehicles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    registration_number TEXT NOT NULL UNIQUE,

    brand TEXT NOT NULL,
    model TEXT NOT NULL,

    max_weight_kg NUMERIC(12, 3) NOT NULL
        CHECK (max_weight_kg > 0),

    max_volume_m3 NUMERIC(12, 3) NOT NULL
        CHECK (max_volume_m3 > 0),

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (
            status IN ('active', 'unavailable', 'retired')
        ),

    comment TEXT,

    created_by UUID NOT NULL
        REFERENCES users(id),

    updated_by UUID
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vehicles_status
    ON vehicles(status);


-- =========================================================
-- 2. DRIVER LICENSE CATEGORIES
-- =========================================================

CREATE TABLE driver_license_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =========================================================
-- 3. EMPLOYEE DRIVER LICENSES
-- =========================================================

CREATE TABLE employee_driver_licenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    employee_id UUID NOT NULL
        REFERENCES employees(id),

    license_category_id UUID NOT NULL
        REFERENCES driver_license_categories(id),

    valid_from DATE NOT NULL,
    valid_until DATE,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT employee_driver_licenses_valid_dates
        CHECK (
            valid_until IS NULL
            OR valid_until >= valid_from
        ),

    CONSTRAINT employee_driver_licenses_unique_period
        UNIQUE (
            employee_id,
            license_category_id,
            valid_from
        )
);

CREATE INDEX idx_employee_driver_licenses_employee
    ON employee_driver_licenses(employee_id);

CREATE INDEX idx_employee_driver_licenses_category
    ON employee_driver_licenses(license_category_id);


-- =========================================================
-- 4. EMPLOYEE-VEHICLE AUTHORIZATIONS
-- =========================================================

CREATE TABLE employee_vehicle_authorizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    employee_id UUID NOT NULL
        REFERENCES employees(id),

    vehicle_id UUID NOT NULL
        REFERENCES vehicles(id),

    valid_from DATE NOT NULL,
    valid_until DATE,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT employee_vehicle_authorizations_valid_dates
        CHECK (
            valid_until IS NULL
            OR valid_until >= valid_from
        ),

    CONSTRAINT employee_vehicle_authorizations_unique_period
        UNIQUE (
            employee_id,
            vehicle_id,
            valid_from
        )
);

CREATE INDEX idx_employee_vehicle_authorizations_employee
    ON employee_vehicle_authorizations(employee_id);

CREATE INDEX idx_employee_vehicle_authorizations_vehicle
    ON employee_vehicle_authorizations(vehicle_id);


-- =========================================================
-- 5. TRIPS
-- =========================================================

CREATE TABLE trips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,

    vehicle_id UUID NOT NULL
        REFERENCES vehicles(id),

    driver_id UUID NOT NULL
        REFERENCES employees(id),

    status TEXT NOT NULL DEFAULT 'planned'
        CHECK (
            status IN (
                'planned',
                'ready',
                'in_transit',
                'delivered',
                'cancelled'
            )
        ),

    planned_departure_at TIMESTAMPTZ,

    actual_departure_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,

    route_version INTEGER NOT NULL DEFAULT 1
        CHECK (route_version > 0),

    created_by UUID NOT NULL
        REFERENCES users(id),

    updated_by UUID
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trips_vehicle
    ON trips(vehicle_id);

CREATE INDEX idx_trips_driver
    ON trips(driver_id);

CREATE INDEX idx_trips_status
    ON trips(status);

CREATE INDEX idx_trips_planned_departure
    ON trips(planned_departure_at);

CREATE UNIQUE INDEX idx_trips_vehicle_active_assignment
    ON trips(vehicle_id)
    WHERE status IN ('ready', 'in_transit');


-- =========================================================
-- 6. TRIP STOPS
-- =========================================================

CREATE TABLE trip_stops (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_id UUID NOT NULL
        REFERENCES trips(id) ON DELETE CASCADE,

    storage_point_id UUID NOT NULL
        REFERENCES storage_points(id),

    sequence_number INTEGER NOT NULL
        CHECK (sequence_number > 0),

    planned_arrival_at TIMESTAMPTZ,
    planned_departure_at TIMESTAMPTZ,

    actual_arrival_at TIMESTAMPTZ,
    actual_departure_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT trip_stops_unique_sequence
        UNIQUE (trip_id, sequence_number),

    CONSTRAINT trip_stops_id_trip_unique
        UNIQUE (id, trip_id),

    CONSTRAINT trip_stops_planned_time_check
        CHECK (
            planned_arrival_at IS NULL
            OR planned_departure_at IS NULL
            OR planned_departure_at >= planned_arrival_at
        ),

    CONSTRAINT trip_stops_actual_time_check
        CHECK (
            actual_arrival_at IS NULL
            OR actual_departure_at IS NULL
            OR actual_departure_at >= actual_arrival_at
        )
);

CREATE INDEX idx_trip_stops_trip
    ON trip_stops(trip_id, sequence_number);

CREATE INDEX idx_trip_stops_storage_point
    ON trip_stops(storage_point_id);


-- =========================================================
-- 7. TRIP EVENTS
-- =========================================================

CREATE TABLE trip_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_id UUID NOT NULL
        REFERENCES trips(id),

    event_type TEXT NOT NULL,

    old_status TEXT,
    new_status TEXT,

    description TEXT,

    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trip_events_trip
    ON trip_events(trip_id, created_at DESC);


-- =========================================================
-- 8. LINK SHIPMENTS TO TRIPS
-- =========================================================

ALTER TABLE shipments
ADD COLUMN trip_id UUID
    REFERENCES trips(id);

CREATE INDEX idx_shipments_trip
    ON shipments(trip_id);


-- =========================================================
-- 9. IMMUTABLE TRIP HISTORY
-- =========================================================

CREATE TRIGGER trg_trip_events_immutable
BEFORE UPDATE OR DELETE
ON trip_events
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();