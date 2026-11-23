-- =========================================================
-- 1. SHIPMENT LOADING MOVEMENTS
-- =========================================================

CREATE TABLE shipment_loading_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_item_id UUID NOT NULL
        REFERENCES shipment_items(id),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    operation_key UUID NOT NULL UNIQUE,

    loaded_by UUID NOT NULL
        REFERENCES users(id),

    comment TEXT,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shipment_loading_movements_item
    ON shipment_loading_movements(
        shipment_item_id,
        loaded_at
    );


-- =========================================================
-- 2. SHIPMENT RECEIPT MOVEMENTS
-- =========================================================

CREATE TABLE shipment_receipt_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_item_id UUID NOT NULL
        REFERENCES shipment_items(id),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    operation_key UUID NOT NULL UNIQUE,

    received_by UUID NOT NULL
        REFERENCES users(id),

    comment TEXT,

    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shipment_receipt_movements_item
    ON shipment_receipt_movements(
        shipment_item_id,
        received_at
    );


-- =========================================================
-- 3. SHIPMENT CARGO MOVEMENTS
-- =========================================================

CREATE TABLE shipment_cargo_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_item_id UUID NOT NULL
        REFERENCES shipment_items(id),

    movement_type TEXT NOT NULL
        CHECK (
            movement_type IN (
                'return',
                'loss',
                'writeoff',
                'responsibility_transfer'
            )
        ),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    operation_key UUID NOT NULL UNIQUE,

    return_storage_point_id UUID
        REFERENCES storage_points(id),

    from_user_id UUID
        REFERENCES users(id),

    to_user_id UUID
        REFERENCES users(id),

    reason TEXT NOT NULL
        CHECK (length(trim(reason)) > 0),

    comment TEXT,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT shipment_cargo_movement_details_check
        CHECK (
            (
                movement_type = 'return'
                AND return_storage_point_id IS NOT NULL
                AND from_user_id IS NULL
                AND to_user_id IS NULL
            )
            OR
            (
                movement_type = 'responsibility_transfer'
                AND return_storage_point_id IS NULL
                AND from_user_id IS NOT NULL
                AND to_user_id IS NOT NULL
                AND from_user_id <> to_user_id
            )
            OR
            (
                movement_type IN ('loss', 'writeoff')
                AND return_storage_point_id IS NULL
                AND from_user_id IS NULL
                AND to_user_id IS NULL
            )
        )
);

CREATE INDEX idx_shipment_cargo_movements_item
    ON shipment_cargo_movements(
        shipment_item_id,
        created_at
    );

CREATE INDEX idx_shipment_cargo_movements_type
    ON shipment_cargo_movements(movement_type);

CREATE INDEX idx_shipment_cargo_movements_return_point
    ON shipment_cargo_movements(return_storage_point_id)
    WHERE return_storage_point_id IS NOT NULL;

CREATE INDEX idx_shipment_cargo_movements_responsible_user
    ON shipment_cargo_movements(to_user_id)
    WHERE to_user_id IS NOT NULL;


-- =========================================================
-- 4. SHIPMENT INCIDENTS
-- =========================================================

CREATE TABLE shipment_incidents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_id UUID NOT NULL
        REFERENCES shipments(id),

    description TEXT NOT NULL
        CHECK (length(trim(description)) > 0),

    comment TEXT,

    reported_by UUID NOT NULL
        REFERENCES users(id),

    reported_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shipment_incidents_shipment
    ON shipment_incidents(
        shipment_id,
        reported_at DESC
    );


-- =========================================================
-- 5. TRIP RESPONSIBILITY TRANSFERS
-- =========================================================

CREATE TABLE trip_responsibility_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    trip_id UUID NOT NULL
        REFERENCES trips(id),

    shipment_item_id UUID NOT NULL
        REFERENCES shipment_items(id),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    from_user_id UUID NOT NULL
        REFERENCES users(id),

    to_user_id UUID NOT NULL
        REFERENCES users(id),

    reason TEXT NOT NULL
        CHECK (length(trim(reason)) > 0),

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT trip_responsibility_transfer_users_check
        CHECK (from_user_id <> to_user_id)
);

CREATE INDEX idx_trip_responsibility_transfers_trip
    ON trip_responsibility_transfers(trip_id);

CREATE INDEX idx_trip_responsibility_transfers_item
    ON trip_responsibility_transfers(shipment_item_id);


-- =========================================================
-- 6. VALIDATE TRIP RESPONSIBILITY TRANSFERS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_responsibility_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    item_shipment_id UUID;
    shipment_trip_id UUID;
BEGIN
    SELECT shipment_id
    INTO item_shipment_id
    FROM shipment_items
    WHERE id = NEW.shipment_item_id;

    IF item_shipment_id IS NULL THEN
        RAISE EXCEPTION 'Shipment item does not exist';
    END IF;

    SELECT trip_id
    INTO shipment_trip_id
    FROM shipments
    WHERE id = item_shipment_id;

    IF shipment_trip_id IS DISTINCT FROM NEW.trip_id THEN
        RAISE EXCEPTION
            'Shipment item is not assigned to this trip';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_trip_responsibility_transfer
BEFORE INSERT OR UPDATE OF
    trip_id,
    shipment_item_id
ON trip_responsibility_transfers
FOR EACH ROW
EXECUTE FUNCTION validate_trip_responsibility_transfer();


-- =========================================================
-- 7. IMMUTABLE CARGO JOURNALS
-- =========================================================

CREATE TRIGGER trg_shipment_loading_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_shipment_receipt_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_receipt_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_shipment_cargo_movements_immutable
BEFORE UPDATE OR DELETE
ON shipment_cargo_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_shipment_incidents_immutable
BEFORE UPDATE OR DELETE
ON shipment_incidents
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_trip_responsibility_transfers_immutable
BEFORE UPDATE OR DELETE
ON trip_responsibility_transfers
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();