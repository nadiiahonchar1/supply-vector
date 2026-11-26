-- =========================================================
-- 1. SHIPMENT CARGO OPERATIONS
-- =========================================================

CREATE TABLE shipment_cargo_operations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_item_id UUID NOT NULL
        REFERENCES shipment_items(id) ON DELETE RESTRICT,

    operation_type TEXT NOT NULL
        CHECK (
            operation_type IN (
                'load',
                'receive',
                'unload_before_departure',
                'return',
                'loss',
                'writeoff',
                'responsibility_transfer'
            )
        ),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    operation_key UUID NOT NULL UNIQUE,

    storage_point_id UUID
        REFERENCES storage_points(id) ON DELETE RESTRICT,

    from_user_id UUID
        REFERENCES users(id) ON DELETE RESTRICT,

    to_user_id UUID
        REFERENCES users(id) ON DELETE RESTRICT,

    reason_code TEXT,

    comment TEXT,

    performed_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_shipment_cargo_operation_details
        CHECK (
            (
                operation_type = 'responsibility_transfer'
                AND storage_point_id IS NULL
                AND from_user_id IS NOT NULL
                AND to_user_id IS NOT NULL
                AND from_user_id <> to_user_id
            )
            OR
            (
                operation_type = 'return'
                AND storage_point_id IS NOT NULL
                AND from_user_id IS NULL
                AND to_user_id IS NULL
            )
            OR
            (
                operation_type IN (
                    'load',
                    'receive',
                    'unload_before_departure',
                    'loss',
                    'writeoff'
                )
                AND storage_point_id IS NULL
                AND from_user_id IS NULL
                AND to_user_id IS NULL
            )
        ),

    CONSTRAINT chk_shipment_cargo_operation_reason
        CHECK (
            reason_code IS NULL
            OR BTRIM(reason_code) <> ''
        )
);

CREATE INDEX idx_shipment_cargo_operations_item
    ON shipment_cargo_operations(
        shipment_item_id,
        occurred_at,
        id
    );

CREATE INDEX idx_shipment_cargo_operations_type
    ON shipment_cargo_operations(operation_type);

CREATE INDEX idx_shipment_cargo_operations_storage_point
    ON shipment_cargo_operations(storage_point_id)
    WHERE storage_point_id IS NOT NULL;

CREATE INDEX idx_shipment_cargo_operations_responsible_user
    ON shipment_cargo_operations(to_user_id)
    WHERE operation_type = 'responsibility_transfer';


-- =========================================================
-- 2. VALIDATE RESPONSIBILITY TRANSFERS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_cargo_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    item_shipment_id UUID;
    shipment_trip_id UUID;
BEGIN
    IF NEW.operation_type <> 'responsibility_transfer' THEN
        RETURN NEW;
    END IF;

    SELECT si.shipment_id
    INTO item_shipment_id
    FROM shipment_items si
    WHERE si.id = NEW.shipment_item_id
    FOR KEY SHARE;

    IF item_shipment_id IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
    END IF;

    SELECT s.trip_id
    INTO shipment_trip_id
    FROM shipments s
    WHERE s.id = item_shipment_id
    FOR KEY SHARE;

    IF shipment_trip_id IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_ASSIGNED_TO_TRIP';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_shipment_cargo_operation
BEFORE INSERT OR UPDATE OF
    shipment_item_id,
    operation_type
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_cargo_operation();


-- =========================================================
-- 3. SHIPMENT INCIDENTS
-- =========================================================

CREATE TABLE shipment_incidents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_id UUID NOT NULL
        REFERENCES shipments(id) ON DELETE RESTRICT,

    description TEXT NOT NULL
        CHECK (BTRIM(description) <> ''),

    comment TEXT,

    reported_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    reported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shipment_incidents_shipment
    ON shipment_incidents(
        shipment_id,
        reported_at DESC
    );


-- =========================================================
-- 4. IMMUTABLE CARGO HISTORY
-- =========================================================

CREATE TRIGGER trg_shipment_cargo_operations_immutable
BEFORE UPDATE OR DELETE
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_shipment_incidents_immutable
BEFORE UPDATE OR DELETE
ON shipment_incidents
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();