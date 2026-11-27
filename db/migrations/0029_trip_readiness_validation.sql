-- =========================================================
-- 1. VEHICLE REQUIRED LICENSE CATEGORIES
-- =========================================================

CREATE TABLE vehicle_required_license_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    vehicle_id UUID NOT NULL
        REFERENCES vehicles(id) ON DELETE RESTRICT,

    license_category_id UUID NOT NULL
        REFERENCES driver_license_categories(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_vehicle_required_license_category
        UNIQUE (vehicle_id, license_category_id)
);


-- =========================================================
-- 2. ROUTE VERSION HISTORY
-- =========================================================

CREATE TABLE trip_route_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_id UUID NOT NULL
        REFERENCES trips(id) ON DELETE RESTRICT,

    version_number INTEGER NOT NULL
        CHECK (version_number > 0),

    reason TEXT NOT NULL
        CHECK (LENGTH(BTRIM(reason)) BETWEEN 1 AND 2000),

    route_snapshot JSONB NOT NULL
        CHECK (
            JSONB_TYPEOF(route_snapshot) = 'array'
            AND JSONB_ARRAY_LENGTH(route_snapshot) >= 2
        ),

    created_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_trip_route_version
        UNIQUE (trip_id, version_number)
);


CREATE INDEX idx_trip_route_versions_trip
    ON trip_route_versions(trip_id, version_number DESC);


-- =========================================================
-- 3. ROUTE APPROVAL HISTORY
-- =========================================================

CREATE TABLE trip_route_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_id UUID NOT NULL
        REFERENCES trips(id) ON DELETE RESTRICT,

    route_version INTEGER NOT NULL
        CHECK (route_version > 0),

    approved_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    comment TEXT,

    approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    operation_key UUID NOT NULL UNIQUE,

    CONSTRAINT fk_trip_route_approval_version
        FOREIGN KEY (trip_id, route_version)
        REFERENCES trip_route_versions(trip_id, version_number)
        ON DELETE RESTRICT
);


CREATE INDEX idx_trip_route_approvals_trip
    ON trip_route_approvals(trip_id, route_version);


-- =========================================================
-- 4. ROUTE HISTORY IMMUTABILITY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_trip_route_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TRIP_ROUTE_HISTORY_IMMUTABLE';
END;
$$;


CREATE TRIGGER trg_trip_route_versions_immutable
BEFORE UPDATE OR DELETE
ON trip_route_versions
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_history_mutation();


CREATE TRIGGER trg_trip_route_approvals_immutable
BEFORE UPDATE OR DELETE
ON trip_route_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_trip_route_history_mutation();


-- =========================================================
-- 5. CURRENT ROUTE SNAPSHOT
-- =========================================================

CREATE OR REPLACE FUNCTION get_trip_route_snapshot(
    p_trip_id UUID
)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        JSONB_AGG(
            JSONB_BUILD_OBJECT(
                'stop_id', ts.id,
                'sequence_number', ts.sequence_number,
                'storage_point_id', ts.storage_point_id
            )
            ORDER BY ts.sequence_number
        ),
        '[]'::JSONB
    )
    FROM trip_stops ts
    WHERE ts.trip_id = p_trip_id;
$$;


-- =========================================================
-- 6. CREATE A ROUTE VERSION
-- =========================================================

CREATE OR REPLACE FUNCTION create_trip_route_version(
    p_trip_id UUID,
    p_user_id UUID,
    p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_trip RECORD;
    v_snapshot JSONB;
    v_version INTEGER;
    v_version_id UUID;
BEGIN
    IF p_trip_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'TRIP_AND_ACTOR_REQUIRED';
    END IF;

    IF p_reason IS NULL
       OR LENGTH(BTRIM(p_reason)) NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION 'ROUTE_VERSION_REASON_REQUIRED';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND is_active = TRUE
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'ACTIVE_USER_REQUIRED';
    END IF;

    SELECT *
    INTO v_trip
    FROM trips
    WHERE id = p_trip_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_NOT_FOUND';
    END IF;

    IF v_trip.status <> 'planned' THEN
        RAISE EXCEPTION 'TRIP_ROUTE_CAN_ONLY_BE_CREATED_WHILE_PLANNED';
    END IF;

    v_snapshot := get_trip_route_snapshot(p_trip_id);

    IF JSONB_ARRAY_LENGTH(v_snapshot) < 2 THEN
        RAISE EXCEPTION 'TRIP_ROUTE_REQUIRES_AT_LEAST_TWO_STOPS';
    END IF;

    SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_version
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
        v_version,
        BTRIM(p_reason),
        v_snapshot,
        p_user_id
    )
    RETURNING id INTO v_version_id;

    UPDATE trips
    SET
        route_version = v_version,
        updated_at = NOW()
    WHERE id = p_trip_id;

    RETURN v_version_id;
END;
$$;


-- =========================================================
-- 7. ROUTE APPROVAL PERMISSION
-- =========================================================

INSERT INTO permissions (code, name)
VALUES (
    'trip_route_approve',
    'Approve trip route'
)
ON CONFLICT (code) DO NOTHING;


CREATE OR REPLACE FUNCTION user_can_approve_trip_route(
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
          AND p.code = 'trip_route_approve'
    );
$$;


-- =========================================================
-- 8. APPROVE THE CURRENT ROUTE VERSION
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
    v_existing RECORD;
    v_approval_id UUID;
    v_current_snapshot JSONB;
    v_approved_snapshot JSONB;
BEGIN
    IF p_trip_id IS NULL
       OR p_user_id IS NULL
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'TRIP_APPROVAL_PARAMETERS_REQUIRED';
    END IF;

    PERFORM 1
    FROM trips
    WHERE id = p_trip_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_existing
    FROM trip_route_approvals
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.trip_id IS DISTINCT FROM p_trip_id
           OR v_existing.approved_by IS DISTINCT FROM p_user_id
           OR v_existing.comment IS DISTINCT FROM p_comment THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    IF NOT user_can_approve_trip_route(p_user_id) THEN
        RAISE EXCEPTION 'TRIP_ROUTE_APPROVAL_PERMISSION_REQUIRED';
    END IF;

    SELECT *
    INTO v_trip
    FROM trips
    WHERE id = p_trip_id;

    IF v_trip.status <> 'planned' THEN
        RAISE EXCEPTION 'TRIP_MUST_BE_PLANNED_FOR_ROUTE_APPROVAL';
    END IF;

    SELECT route_snapshot
    INTO v_approved_snapshot
    FROM trip_route_versions
    WHERE trip_id = p_trip_id
      AND version_number = v_trip.route_version;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CURRENT_ROUTE_VERSION_NOT_FOUND';
    END IF;

    v_current_snapshot := get_trip_route_snapshot(p_trip_id);

    IF v_current_snapshot IS DISTINCT FROM v_approved_snapshot THEN
        RAISE EXCEPTION 'TRIP_ROUTE_VERSION_OUTDATED';
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
        NULLIF(BTRIM(p_comment), ''),
        p_operation_key
    )
    RETURNING id INTO v_approval_id;

    RETURN v_approval_id;
END;
$$;


-- =========================================================
-- 9. DRIVER AND VEHICLE VALIDATION
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
        t.id,
        t.vehicle_id,
        t.driver_id,
        v.status AS vehicle_status,
        e.is_active AS driver_active,
        e.user_id AS driver_user_id,
        u.is_active AS user_active,
        u.deleted_at AS user_deleted_at
    INTO v_trip
    FROM trips t
    JOIN vehicles v
        ON v.id = t.vehicle_id
    JOIN employees e
        ON e.id = t.driver_id
    JOIN users u
        ON u.id = e.user_id
    WHERE t.id = p_trip_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_DRIVER_OR_VEHICLE_NOT_FOUND';
    END IF;

    IF v_trip.vehicle_status <> 'active' THEN
        RAISE EXCEPTION 'TRIP_VEHICLE_NOT_ACTIVE';
    END IF;

    IF NOT v_trip.driver_active
       OR NOT v_trip.user_active
       OR v_trip.user_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRIP_DRIVER_NOT_ACTIVE';
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
        RAISE EXCEPTION 'DRIVER_VEHICLE_AUTHORIZATION_INVALID';
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
        RAISE EXCEPTION 'DRIVER_REQUIRED_LICENSE_CATEGORY_MISSING';
    END IF;
END;
$$;


-- =========================================================
-- 10. SHIPMENT ROUTE VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_shipment_routes(
    p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_shipment RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM shipments
        WHERE trip_id = p_trip_id
    ) THEN
        RAISE EXCEPTION 'TRIP_HAS_NO_ASSIGNED_SHIPMENTS';
    END IF;

    FOR v_shipment IN
        SELECT
            s.id,
            s.status,
            s.source_storage_point_id,
            s.destination_storage_point_id
        FROM shipments s
        WHERE s.trip_id = p_trip_id
        ORDER BY s.id
    LOOP
        IF v_shipment.status <> 'pending' THEN
            RAISE EXCEPTION 'TRIP_CONTAINS_NON_PENDING_SHIPMENT';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM shipment_items si
            WHERE si.shipment_id = v_shipment.id
        ) THEN
            RAISE EXCEPTION 'TRIP_SHIPMENT_HAS_NO_ITEMS';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM trip_stops source_stop
            JOIN trip_stops destination_stop
                ON destination_stop.trip_id = source_stop.trip_id
            WHERE source_stop.trip_id = p_trip_id
              AND source_stop.storage_point_id =
                  v_shipment.source_storage_point_id
              AND destination_stop.storage_point_id =
                  v_shipment.destination_storage_point_id
              AND source_stop.sequence_number <
                  destination_stop.sequence_number
        ) THEN
            RAISE EXCEPTION 'SHIPMENT_ROUTE_ORDER_INVALID';
        END IF;
    END LOOP;
END;
$$;


-- =========================================================
-- 11. CAPACITY VALIDATION FOR EACH ROUTE LEG
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_leg_capacity(
    p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_vehicle RECORD;
    v_leg RECORD;

    v_weight NUMERIC;
    v_volume NUMERIC;
BEGIN
    SELECT
        v.max_weight_kg,
        v.max_volume_m3
    INTO v_vehicle
    FROM trips t
    JOIN vehicles v
        ON v.id = t.vehicle_id
    WHERE t.id = p_trip_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_OR_VEHICLE_NOT_FOUND';
    END IF;

    FOR v_leg IN
        SELECT
            current_stop.sequence_number AS leg_start,
            next_stop.sequence_number AS leg_end
        FROM trip_stops current_stop
        JOIN trip_stops next_stop
            ON next_stop.trip_id = current_stop.trip_id
           AND next_stop.sequence_number =
               current_stop.sequence_number + 1
        WHERE current_stop.trip_id = p_trip_id
        ORDER BY current_stop.sequence_number
    LOOP

        IF EXISTS (
            SELECT 1
            FROM shipments s
            JOIN trip_stops source_stop
                ON source_stop.trip_id = p_trip_id
               AND source_stop.storage_point_id =
                   s.source_storage_point_id
            JOIN trip_stops destination_stop
                ON destination_stop.trip_id = p_trip_id
               AND destination_stop.storage_point_id =
                   s.destination_storage_point_id
            JOIN shipment_items si
                ON si.shipment_id = s.id
            JOIN products p
                ON p.id = si.product_id
            WHERE s.trip_id = p_trip_id
              AND source_stop.sequence_number <= v_leg.leg_start
              AND destination_stop.sequence_number > v_leg.leg_start
              AND (
                  p.weight_kg IS NULL
                  OR p.volume_m3 IS NULL
              )
        ) THEN
            RAISE EXCEPTION 'TRIP_CARGO_DIMENSIONS_MISSING';
        END IF;

        SELECT
            COALESCE(
                SUM(si.planned_quantity * p.weight_kg),
                0
            ),
            COALESCE(
                SUM(si.planned_quantity * p.volume_m3),
                0
            )
        INTO
            v_weight,
            v_volume
        FROM shipments s
        JOIN trip_stops source_stop
            ON source_stop.trip_id = p_trip_id
           AND source_stop.storage_point_id =
               s.source_storage_point_id
        JOIN trip_stops destination_stop
            ON destination_stop.trip_id = p_trip_id
           AND destination_stop.storage_point_id =
               s.destination_storage_point_id
        JOIN shipment_items si
            ON si.shipment_id = s.id
        JOIN products p
            ON p.id = si.product_id
        WHERE s.trip_id = p_trip_id
          AND s.status = 'pending'
          AND source_stop.sequence_number <= v_leg.leg_start
          AND destination_stop.sequence_number > v_leg.leg_start;

        IF v_weight > v_vehicle.max_weight_kg THEN
            RAISE EXCEPTION 'TRIP_LEG_WEIGHT_CAPACITY_EXCEEDED';
        END IF;

        IF v_volume > v_vehicle.max_volume_m3 THEN
            RAISE EXCEPTION 'TRIP_LEG_VOLUME_CAPACITY_EXCEEDED';
        END IF;

    END LOOP;
END;
$$;


-- =========================================================
-- 12. COMPLETE TRIP READINESS VALIDATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_readiness(
    p_trip_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_trip RECORD;
    v_current_snapshot JSONB;
    v_approved_snapshot JSONB;
BEGIN
    SELECT *
    INTO v_trip
    FROM trips
    WHERE id = p_trip_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_NOT_FOUND';
    END IF;

    IF v_trip.status <> 'planned' THEN
        RAISE EXCEPTION 'TRIP_MUST_BE_PLANNED_FOR_READINESS_CHECK';
    END IF;

    PERFORM validate_trip_driver_and_vehicle(p_trip_id);

    PERFORM validate_trip_shipment_routes(p_trip_id);

    PERFORM validate_trip_leg_capacity(p_trip_id);

    SELECT route_snapshot
    INTO v_approved_snapshot
    FROM trip_route_versions
    WHERE trip_id = p_trip_id
      AND version_number = v_trip.route_version;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRIP_ROUTE_VERSION_NOT_FOUND';
    END IF;

    v_current_snapshot := get_trip_route_snapshot(p_trip_id);

    IF v_current_snapshot IS DISTINCT FROM v_approved_snapshot THEN
        RAISE EXCEPTION 'TRIP_ROUTE_VERSION_OUTDATED';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM trip_route_approvals
        WHERE trip_id = p_trip_id
          AND route_version = v_trip.route_version
    ) THEN
        RAISE EXCEPTION 'TRIP_ROUTE_VERSION_NOT_APPROVED';
    END IF;

    IF JSONB_ARRAY_LENGTH(v_current_snapshot) < 2 THEN
        RAISE EXCEPTION 'TRIP_ROUTE_REQUIRES_AT_LEAST_TWO_STOPS';
    END IF;
END;
$$;


-- =========================================================
-- 13. ENFORCE READINESS BEFORE STATUS TRANSITION
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


CREATE TRIGGER trg_trip_readiness_guard
BEFORE UPDATE OF status
ON trips
FOR EACH ROW
EXECUTE FUNCTION enforce_trip_readiness();