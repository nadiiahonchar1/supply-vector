-- =========================================================
-- 1. TRANSFER REQUESTS
-- =========================================================

CREATE TABLE transfer_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    request_number BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,

    destination_storage_point_id UUID NOT NULL
        REFERENCES storage_points(id),

    created_by UUID NOT NULL
        REFERENCES users(id),

    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (
            status IN (
                'draft',
                'pending',
                'approved',
                'in_progress',
                'fulfilled',
                'partially_fulfilled',
                'cancelled'
            )
        ),

    priority TEXT NOT NULL DEFAULT 'normal'
        CHECK (
            priority IN ('low', 'normal', 'high', 'urgent')
        ),

    priority_reason TEXT,

    urgent_approval_status TEXT NOT NULL DEFAULT 'not_required'
        CHECK (
            urgent_approval_status IN (
                'not_required',
                'pending',
                'approved',
                'rejected'
            )
        ),

    submitted_at TIMESTAMPTZ,
    approved_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT transfer_requests_priority_reason_check
        CHECK (
            (
                priority IN ('low', 'normal')
                AND priority_reason IS NULL
            )
            OR
            (
                priority = 'high'
                AND priority_reason IS NOT NULL
                AND length(trim(priority_reason)) BETWEEN 1 AND 500
            )
            OR
            (
                priority = 'urgent'
                AND priority_reason IS NOT NULL
                AND length(trim(priority_reason)) BETWEEN 1 AND 2000
            )
        ),

    CONSTRAINT transfer_requests_urgent_approval_check
        CHECK (
            (
                priority = 'urgent'
                AND urgent_approval_status IN (
                    'pending',
                    'approved',
                    'rejected'
                )
            )
            OR
            (
                priority <> 'urgent'
                AND urgent_approval_status = 'not_required'
            )
        )
);

CREATE INDEX idx_transfer_requests_destination
    ON transfer_requests(destination_storage_point_id);

CREATE INDEX idx_transfer_requests_created_by
    ON transfer_requests(created_by);

CREATE INDEX idx_transfer_requests_status
    ON transfer_requests(status);

CREATE INDEX idx_transfer_requests_priority
    ON transfer_requests(priority);

CREATE INDEX idx_transfer_requests_created_at
    ON transfer_requests(created_at DESC);


-- =========================================================
-- 2. TRANSFER REQUEST ITEMS
-- =========================================================

CREATE TABLE transfer_request_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id) ON DELETE CASCADE,

    product_id UUID NOT NULL
        REFERENCES products(id),

    requested_quantity INTEGER NOT NULL
        CHECK (requested_quantity > 0),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT transfer_request_items_unique_product
        UNIQUE (transfer_request_id, product_id),

    CONSTRAINT transfer_request_items_id_request_unique
        UNIQUE (id, transfer_request_id)
);

CREATE INDEX idx_transfer_request_items_request
    ON transfer_request_items(transfer_request_id);

CREATE INDEX idx_transfer_request_items_product
    ON transfer_request_items(product_id);


-- =========================================================
-- 3. TRANSFER REQUEST SOURCES
-- =========================================================

CREATE TABLE transfer_request_sources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL,

    transfer_request_item_id UUID NOT NULL,

    source_storage_point_id UUID NOT NULL
        REFERENCES storage_points(id),

    allocated_quantity INTEGER NOT NULL
        CHECK (allocated_quantity > 0),

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT transfer_request_sources_item_request_fk
        FOREIGN KEY (
            transfer_request_item_id,
            transfer_request_id
        )
        REFERENCES transfer_request_items (
            id,
            transfer_request_id
        )
        ON DELETE CASCADE,

    CONSTRAINT transfer_request_sources_unique_source
        UNIQUE (
            transfer_request_item_id,
            source_storage_point_id
        ),

    CONSTRAINT transfer_request_sources_id_item_unique
        UNIQUE (id, transfer_request_item_id)
);

CREATE INDEX idx_transfer_request_sources_request
    ON transfer_request_sources(transfer_request_id);

CREATE INDEX idx_transfer_request_sources_item
    ON transfer_request_sources(transfer_request_item_id);

CREATE INDEX idx_transfer_request_sources_storage_point
    ON transfer_request_sources(source_storage_point_id);


-- =========================================================
-- 4. VALIDATE SOURCE AND DESTINATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    destination_id UUID;
BEGIN
    SELECT destination_storage_point_id
    INTO destination_id
    FROM transfer_requests
    WHERE id = NEW.transfer_request_id;

    IF destination_id IS NULL THEN
        RAISE EXCEPTION 'Transfer request does not exist';
    END IF;

    IF NEW.source_storage_point_id = destination_id THEN
        RAISE EXCEPTION
            'Source storage point cannot be the destination';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_transfer_request_source
BEFORE INSERT OR UPDATE OF
    transfer_request_id,
    source_storage_point_id
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_source();


-- =========================================================
-- 5. TRANSFER REQUEST EVENTS
-- =========================================================

CREATE TABLE transfer_request_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id),

    event_type TEXT NOT NULL,

    old_status TEXT,
    new_status TEXT,

    description TEXT,

    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transfer_request_events_request
    ON transfer_request_events(
        transfer_request_id,
        created_at DESC
    );


-- =========================================================
-- 6. TRANSFER REQUEST COMMENTS
-- =========================================================

CREATE TABLE transfer_request_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id),

    comment TEXT NOT NULL
        CHECK (length(trim(comment)) > 0),

    created_by UUID NOT NULL
        REFERENCES users(id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transfer_request_comments_request
    ON transfer_request_comments(
        transfer_request_id,
        created_at
    );


-- =========================================================
-- 7. PRIORITY HISTORY
-- =========================================================

CREATE TABLE transfer_request_priority_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id),

    old_priority TEXT
        CHECK (
            old_priority IS NULL
            OR old_priority IN ('low', 'normal', 'high', 'urgent')
        ),

    new_priority TEXT NOT NULL
        CHECK (
            new_priority IN ('low', 'normal', 'high', 'urgent')
        ),

    reason TEXT,

    changed_by UUID NOT NULL
        REFERENCES users(id),

    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transfer_request_priority_history_request
    ON transfer_request_priority_history(
        transfer_request_id,
        changed_at DESC
    );


-- =========================================================
-- 8. URGENT PRIORITY APPROVALS
-- =========================================================

CREATE TABLE transfer_request_urgent_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    transfer_request_id UUID NOT NULL
        REFERENCES transfer_requests(id),

    decision TEXT NOT NULL
        CHECK (decision IN ('approved', 'rejected')),

    comment TEXT,

    decided_by UUID NOT NULL
        REFERENCES users(id),

    decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transfer_request_urgent_approvals_request
    ON transfer_request_urgent_approvals(
        transfer_request_id,
        decided_at DESC
    );


-- =========================================================
-- 9. LINK INVENTORY RESERVATIONS TO REQUEST SOURCES
-- =========================================================

ALTER TABLE inventory_reservations
ADD CONSTRAINT inventory_reservations_transfer_request_source_fk
FOREIGN KEY (transfer_request_source_id)
REFERENCES transfer_request_sources(id);


-- =========================================================
-- 10. IMMUTABILITY OF HISTORY TABLES
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'This history table is append-only';
END;
$$;

CREATE TRIGGER trg_transfer_request_events_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_events
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_transfer_request_comments_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_comments
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_transfer_request_priority_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_priority_history
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_transfer_request_urgent_approvals_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_urgent_approvals
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();