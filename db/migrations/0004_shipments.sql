-- =========================================================
-- 1. SHIPMENTS
-- =========================================================

CREATE TABLE shipments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id),

    source_storage_point_id UUID NOT NULL
        REFERENCES storage_points(id),

    destination_storage_point_id UUID NOT NULL
        REFERENCES storage_points(id),

    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (
            status IN (
                'pending',
                'in_progress',
                'partially_delivered',
                'delivered',
                'returned',
                'lost',
                'settled',
                'cancelled',
                'partially_fulfilled'
            )
        ),

    created_by UUID NOT NULL
        REFERENCES users(id),

    departed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT shipments_different_storage_points
        CHECK (
            source_storage_point_id
            <> destination_storage_point_id
        )
);

CREATE INDEX idx_shipments_transfer_request
    ON shipments(transfer_request_id);

CREATE INDEX idx_shipments_source
    ON shipments(source_storage_point_id);

CREATE INDEX idx_shipments_destination
    ON shipments(destination_storage_point_id);

CREATE INDEX idx_shipments_status
    ON shipments(status);

CREATE INDEX idx_shipments_created_at
    ON shipments(created_at DESC);


-- =========================================================
-- 2. SHIPMENT ITEMS
-- =========================================================

CREATE TABLE shipment_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_id UUID NOT NULL
        REFERENCES shipments(id) ON DELETE CASCADE,

    transfer_request_source_id UUID NOT NULL
        REFERENCES transfer_request_sources(id),

    product_id UUID NOT NULL
        REFERENCES products(id),

    planned_quantity INTEGER NOT NULL
        CHECK (planned_quantity > 0),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT shipment_items_unique_source
        UNIQUE (
            shipment_id,
            transfer_request_source_id
        ),

    CONSTRAINT shipment_items_id_shipment_unique
        UNIQUE (id, shipment_id)
);

CREATE INDEX idx_shipment_items_shipment
    ON shipment_items(shipment_id);

CREATE INDEX idx_shipment_items_source
    ON shipment_items(transfer_request_source_id);

CREATE INDEX idx_shipment_items_product
    ON shipment_items(product_id);


-- =========================================================
-- 3. VALIDATE SHIPMENT ITEMS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    shipment_request_id UUID;
    shipment_source_id UUID;
    shipment_destination_id UUID;

    source_request_id UUID;
    source_point_id UUID;
    source_product_id UUID;
BEGIN
    SELECT
        transfer_request_id,
        source_storage_point_id,
        destination_storage_point_id
    INTO
        shipment_request_id,
        shipment_source_id,
        shipment_destination_id
    FROM shipments
    WHERE id = NEW.shipment_id;

    IF shipment_request_id IS NULL THEN
        RAISE EXCEPTION 'Shipment does not exist';
    END IF;

    SELECT
        trs.transfer_request_id,
        trs.source_storage_point_id,
        tri.product_id
    INTO
        source_request_id,
        source_point_id,
        source_product_id
    FROM transfer_request_sources trs
    JOIN transfer_request_items tri
        ON tri.id = trs.transfer_request_item_id
    WHERE trs.id = NEW.transfer_request_source_id;

    IF source_request_id IS NULL THEN
        RAISE EXCEPTION 'Transfer request source does not exist';
    END IF;

    IF source_request_id <> shipment_request_id THEN
        RAISE EXCEPTION
            'Shipment and source allocation belong to different requests';
    END IF;

    IF source_point_id <> shipment_source_id THEN
        RAISE EXCEPTION
            'Shipment source does not match source allocation';
    END IF;

    IF source_product_id <> NEW.product_id THEN
        RAISE EXCEPTION
            'Shipment item product does not match request item product';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM transfer_requests
        WHERE id = shipment_request_id
          AND destination_storage_point_id = shipment_destination_id
    ) THEN
        RAISE EXCEPTION
            'Shipment destination does not match transfer request destination';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_shipment_item
BEFORE INSERT OR UPDATE OF
    shipment_id,
    transfer_request_source_id,
    product_id
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_item();


-- =========================================================
-- 4. SHIPMENT EVENTS
-- =========================================================

CREATE TABLE shipment_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    shipment_id UUID NOT NULL
        REFERENCES shipments(id),

    event_type TEXT NOT NULL,

    old_status TEXT,
    new_status TEXT,

    description TEXT,

    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_shipment_events_shipment
    ON shipment_events(
        shipment_id,
        created_at DESC
    );


-- =========================================================
-- 5. IMMUTABLE SHIPMENT HISTORY
-- =========================================================

CREATE TRIGGER trg_shipment_events_immutable
BEFORE UPDATE OR DELETE
ON shipment_events
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();