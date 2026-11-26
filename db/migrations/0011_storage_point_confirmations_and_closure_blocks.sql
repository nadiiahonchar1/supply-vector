-- =========================================================
-- 1. STORAGE POINT OPERATION CONFIRMATIONS
-- =========================================================

CREATE TABLE storage_point_operation_confirmations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    storage_point_id UUID NOT NULL
        REFERENCES storage_points(id) ON DELETE RESTRICT,

    operation_type TEXT NOT NULL
        CHECK (BTRIM(operation_type) <> ''),

    operation_key UUID NOT NULL,

    confirmed_by UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,

    confirmed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    comment TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_storage_point_operation_confirmation
        UNIQUE (
            storage_point_id,
            operation_type,
            operation_key,
            confirmed_by
        )
);

CREATE INDEX idx_storage_point_confirmations_operation
    ON storage_point_operation_confirmations (
        operation_type,
        operation_key
    );

CREATE INDEX idx_storage_point_confirmations_employee
    ON storage_point_operation_confirmations (
        confirmed_by,
        confirmed_at DESC
    );


-- =========================================================
-- 2. VALIDATE STORAGE POINT OPERATION CONFIRMATION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_storage_point_operation_confirmation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_storage_point_status TEXT;
    v_is_responsible BOOLEAN;
BEGIN
    SELECT status
    INTO v_storage_point_status
    FROM storage_points
    WHERE id = NEW.storage_point_id
    FOR KEY SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
    END IF;

    IF v_storage_point_status <> 'unavailable' THEN
        RAISE EXCEPTION 'CONFIRMATION_NOT_REQUIRED_FOR_STORAGE_POINT_STATUS';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM storage_point_responsibles spr
        JOIN employees e
            ON e.id = spr.employee_id
        WHERE spr.storage_point_id = NEW.storage_point_id
          AND spr.employee_id = NEW.confirmed_by
          AND spr.valid_from <= CURRENT_DATE
          AND (
              spr.valid_until IS NULL
              OR spr.valid_until >= CURRENT_DATE
          )
          AND e.is_active = TRUE
    )
    INTO v_is_responsible;

    IF NOT v_is_responsible THEN
        RAISE EXCEPTION 'ACTIVE_STORAGE_POINT_RESPONSIBLE_REQUIRED';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_storage_point_operation_confirmation
BEFORE INSERT ON storage_point_operation_confirmations
FOR EACH ROW
EXECUTE FUNCTION validate_storage_point_operation_confirmation();


-- =========================================================
-- 3. VERIFY ALL ACTIVE RESPONSIBLE PERSONS CONFIRMED
-- =========================================================

CREATE OR REPLACE FUNCTION assert_storage_point_operation_confirmed(
    p_storage_point_id UUID,
    p_operation_type TEXT,
    p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
    v_responsible_count INTEGER;
    v_confirmation_count INTEGER;
BEGIN
    IF p_storage_point_id IS NULL
       OR p_operation_type IS NULL
       OR BTRIM(p_operation_type) = ''
       OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'INVALID_STORAGE_POINT_CONFIRMATION_REFERENCE';
    END IF;

    SELECT status
    INTO v_status
    FROM storage_points
    WHERE id = p_storage_point_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_POINT_NOT_FOUND';
    END IF;

    IF v_status = 'closed' THEN
        RAISE EXCEPTION 'STORAGE_POINT_CLOSED';
    END IF;

    IF v_status <> 'unavailable' THEN
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_responsible_count
    FROM storage_point_responsibles spr
    JOIN employees e
        ON e.id = spr.employee_id
    WHERE spr.storage_point_id = p_storage_point_id
      AND spr.valid_from <= CURRENT_DATE
      AND (
          spr.valid_until IS NULL
          OR spr.valid_until >= CURRENT_DATE
      )
      AND e.is_active = TRUE;

    IF v_responsible_count = 0 THEN
        RAISE EXCEPTION 'NO_ACTIVE_STORAGE_POINT_RESPONSIBLES';
    END IF;

    SELECT COUNT(DISTINCT c.confirmed_by)
    INTO v_confirmation_count
    FROM storage_point_operation_confirmations c
    JOIN storage_point_responsibles spr
        ON spr.storage_point_id = c.storage_point_id
       AND spr.employee_id = c.confirmed_by
    JOIN employees e
        ON e.id = spr.employee_id
    WHERE c.storage_point_id = p_storage_point_id
      AND c.operation_type = p_operation_type
      AND c.operation_key = p_operation_key
      AND spr.valid_from <= CURRENT_DATE
      AND (
          spr.valid_until IS NULL
          OR spr.valid_until >= CURRENT_DATE
      )
      AND e.is_active = TRUE;

    IF v_confirmation_count <> v_responsible_count THEN
        RAISE EXCEPTION 'ALL_STORAGE_POINT_RESPONSIBLES_MUST_CONFIRM';
    END IF;
END;
$$;


-- =========================================================
-- 4. IMMUTABLE CONFIRMATION HISTORY
-- =========================================================

CREATE TRIGGER trg_storage_point_operation_confirmations_immutable
BEFORE UPDATE OR DELETE ON storage_point_operation_confirmations
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 5. STORAGE POINT CLOSURE CYCLES
-- =========================================================

CREATE TABLE storage_point_closures (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    storage_point_id UUID NOT NULL
        REFERENCES storage_points(id) ON DELETE RESTRICT,

    closed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    closed_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    reopened_at TIMESTAMPTZ,

    reopened_by UUID
        REFERENCES users(id) ON DELETE RESTRICT,

    closure_reason TEXT,

    reopening_reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT storage_point_closure_reopening_consistency
        CHECK (
            (reopened_at IS NULL AND reopened_by IS NULL)
            OR
            (reopened_at IS NOT NULL AND reopened_by IS NOT NULL)
        ),

    CONSTRAINT storage_point_closure_reopening_after_closing
        CHECK (
            reopened_at IS NULL
            OR reopened_at >= closed_at
        ),

    CONSTRAINT storage_point_closure_reason_not_empty
        CHECK (
            closure_reason IS NULL
            OR BTRIM(closure_reason) <> ''
        ),

    CONSTRAINT storage_point_reopening_reason_not_empty
        CHECK (
            reopening_reason IS NULL
            OR BTRIM(reopening_reason) <> ''
        )
);

CREATE UNIQUE INDEX uq_storage_point_active_closure
    ON storage_point_closures(storage_point_id)
    WHERE reopened_at IS NULL;

CREATE INDEX idx_storage_point_closures_history
    ON storage_point_closures(storage_point_id, closed_at DESC);


-- =========================================================
-- 6. CLOSURE INVENTORY BLOCKS
-- =========================================================

CREATE TABLE storage_point_closure_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    closure_id UUID NOT NULL
        REFERENCES storage_point_closures(id) ON DELETE RESTRICT,

    inventory_id UUID NOT NULL
        REFERENCES inventory(id) ON DELETE RESTRICT,

    product_id UUID NOT NULL
        REFERENCES products(id) ON DELETE RESTRICT,

    initial_quantity INTEGER NOT NULL,

    released_quantity INTEGER NOT NULL DEFAULT 0,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_storage_point_closure_inventory
        UNIQUE (closure_id, inventory_id),

    CONSTRAINT closure_block_initial_quantity_valid
        CHECK (initial_quantity >= 0),

    CONSTRAINT closure_block_released_quantity_valid
        CHECK (
            released_quantity >= 0
            AND released_quantity <= initial_quantity
        )
);

CREATE INDEX idx_storage_point_closure_blocks_inventory
    ON storage_point_closure_blocks(inventory_id);


-- =========================================================
-- 7. CLOSURE INVENTORY INSPECTIONS
-- =========================================================

CREATE TABLE storage_point_closure_inspections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    closure_block_id UUID NOT NULL
        REFERENCES storage_point_closure_blocks(id) ON DELETE RESTRICT,

    inspected_quantity INTEGER NOT NULL,

    suitable_quantity INTEGER NOT NULL,

    inspected_by UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,

    comment TEXT,

    inspected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT closure_inspection_quantities_valid
        CHECK (
            inspected_quantity >= 0
            AND suitable_quantity >= 0
            AND suitable_quantity <= inspected_quantity
        )
);

CREATE INDEX idx_storage_point_closure_inspections_block
    ON storage_point_closure_inspections(
        closure_block_id,
        inspected_at DESC
    );


-- =========================================================
-- 8. CLOSURE BLOCK MOVEMENTS
-- =========================================================

CREATE TABLE storage_point_closure_block_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    closure_block_id UUID NOT NULL
        REFERENCES storage_point_closure_blocks(id) ON DELETE RESTRICT,

    movement_type TEXT NOT NULL
        CHECK (movement_type IN ('block', 'release')),

    quantity INTEGER NOT NULL
        CHECK (quantity > 0),

    inspection_id UUID
        REFERENCES storage_point_closure_inspections(id)
        ON DELETE RESTRICT,

    operation_key UUID NOT NULL,

    reference_type TEXT,
    reference_id UUID,

    reason_code TEXT NOT NULL
        CHECK (BTRIM(reason_code) <> ''),

    created_by UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_closure_block_movement_operation
        UNIQUE (operation_key),

    CONSTRAINT closure_block_movement_inspection_check
        CHECK (
            (movement_type = 'block' AND inspection_id IS NULL)
            OR
            (movement_type = 'release' AND inspection_id IS NOT NULL)
        )
);

CREATE INDEX idx_closure_block_movements_history
    ON storage_point_closure_block_movements(
        closure_block_id,
        created_at
    );


-- =========================================================
-- 9. IMMUTABLE CLOSURE HISTORY
-- =========================================================

CREATE TRIGGER trg_storage_point_closure_inspections_immutable
BEFORE UPDATE OR DELETE ON storage_point_closure_inspections
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_storage_point_closure_movements_immutable
BEFORE UPDATE OR DELETE ON storage_point_closure_block_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_history_mutation();


-- =========================================================
-- 10. CREATE CLOSURE INVENTORY SNAPSHOT
-- =========================================================

CREATE OR REPLACE FUNCTION create_storage_point_closure_blocks(
    p_storage_point_id UUID,
    p_user_id UUID,
    p_closure_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_storage_point RECORD;
    v_closure_id UUID;
    v_inventory RECORD;
BEGIN
    IF p_storage_point_id IS NULL OR p_user_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_CLOSURE_ARGUMENTS';
    END IF;

    PERFORM 1
    FROM storage_points
    WHERE id = p_storage_point_id
      AND status = 'closed'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'STORAGE_POINT_MUST_BE_CLOSED';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM storage_point_closures
        WHERE storage_point_id = p_storage_point_id
          AND reopened_at IS NULL
    ) THEN
        RAISE EXCEPTION 'ACTIVE_STORAGE_POINT_CLOSURE_ALREADY_EXISTS';
    END IF;

    INSERT INTO storage_point_closures (
        storage_point_id,
        closed_by,
        closure_reason
    )
    VALUES (
        p_storage_point_id,
        p_user_id,
        p_closure_reason
    )
    RETURNING id INTO v_closure_id;

    FOR v_inventory IN
        SELECT *
        FROM inventory
        WHERE storage_point_id = p_storage_point_id
        ORDER BY id
        FOR UPDATE
    LOOP
        INSERT INTO storage_point_closure_blocks (
            closure_id,
            inventory_id,
            product_id,
            initial_quantity,
            released_quantity
        )
        VALUES (
            v_closure_id,
            v_inventory.id,
            v_inventory.product_id,
            v_inventory.quantity,
            0
        );

        INSERT INTO storage_point_closure_block_movements (
            closure_block_id,
            movement_type,
            quantity,
            operation_key,
            reason_code,
            created_by
        )
        SELECT
            cb.id,
            'block',
            cb.initial_quantity,
            gen_random_uuid(),
            'storage_point_closed',
            p_user_id
        FROM storage_point_closure_blocks cb
        WHERE cb.closure_id = v_closure_id
          AND cb.inventory_id = v_inventory.id;
    END LOOP;

    RETURN v_closure_id;
END;
$$;


-- =========================================================
-- 11. INSPECT CLOSURE INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION inspect_storage_point_closure_stock(
    p_closure_block_id UUID,
    p_inspected_quantity INTEGER,
    p_suitable_quantity INTEGER,
    p_employee_id UUID,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_block RECORD;
    v_storage_point_id UUID;
    v_inspection_id UUID;
    v_is_responsible BOOLEAN;
BEGIN
    IF p_inspected_quantity IS NULL
       OR p_suitable_quantity IS NULL
       OR p_inspected_quantity < 0
       OR p_suitable_quantity < 0
       OR p_suitable_quantity > p_inspected_quantity THEN
        RAISE EXCEPTION 'INVALID_CLOSURE_INSPECTION_QUANTITIES';
    END IF;

    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'INSPECTOR_REQUIRED';
    END IF;

    SELECT
        cb.*,
        sc.storage_point_id,
        sc.reopened_at
    INTO v_block
    FROM storage_point_closure_blocks cb
    JOIN storage_point_closures sc
        ON sc.id = cb.closure_id
    WHERE cb.id = p_closure_block_id
    FOR UPDATE OF cb, sc;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLOSURE_BLOCK_NOT_FOUND';
    END IF;

    IF v_block.reopened_at IS NOT NULL THEN
        RAISE EXCEPTION 'CLOSURE_ALREADY_REOPENED';
    END IF;

    IF p_inspected_quantity > v_block.initial_quantity THEN
        RAISE EXCEPTION 'INSPECTION_EXCEEDS_CLOSURE_SNAPSHOT';
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM storage_point_responsibles spr
        JOIN employees e
            ON e.id = spr.employee_id
        WHERE spr.storage_point_id = v_block.storage_point_id
          AND spr.employee_id = p_employee_id
          AND spr.valid_from <= CURRENT_DATE
          AND (
              spr.valid_until IS NULL
              OR spr.valid_until >= CURRENT_DATE
          )
          AND e.is_active = TRUE
    )
    INTO v_is_responsible;

    IF NOT v_is_responsible THEN
        RAISE EXCEPTION 'ACTIVE_STORAGE_POINT_RESPONSIBLE_REQUIRED';
    END IF;

    INSERT INTO storage_point_closure_inspections (
        closure_block_id,
        inspected_quantity,
        suitable_quantity,
        inspected_by,
        comment
    )
    VALUES (
        p_closure_block_id,
        p_inspected_quantity,
        p_suitable_quantity,
        p_employee_id,
        p_comment
    )
    RETURNING id INTO v_inspection_id;

    RETURN v_inspection_id;
END;
$$;


-- =========================================================
-- 12. RELEASE INSPECTED CLOSURE INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION release_storage_point_closure_block(
    p_closure_block_id UUID,
    p_quantity INTEGER,
    p_inspection_id UUID,
    p_user_id UUID,
    p_operation_key UUID,
    p_reason_code TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_block RECORD;
    v_inspection RECORD;
    v_existing RECORD;

    v_released_from_inspection INTEGER;
    v_remaining_block_quantity INTEGER;
    v_movement_id UUID;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL OR p_operation_key IS NULL THEN
        RAISE EXCEPTION 'ACTOR_AND_OPERATION_KEY_REQUIRED';
    END IF;

    IF p_reason_code IS NULL OR BTRIM(p_reason_code) = '' THEN
        RAISE EXCEPTION 'CLOSURE_BLOCK_RELEASE_REASON_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM storage_point_closure_block_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.closure_block_id
                IS DISTINCT FROM p_closure_block_id
           OR v_existing.movement_type <> 'release'
           OR v_existing.quantity IS DISTINCT FROM p_quantity
           OR v_existing.inspection_id IS DISTINCT FROM p_inspection_id
           OR v_existing.created_by IS DISTINCT FROM p_user_id
           OR v_existing.reason_code IS DISTINCT FROM p_reason_code THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;

    SELECT
        cb.*,
        sc.reopened_at
    INTO v_block
    FROM storage_point_closure_blocks cb
    JOIN storage_point_closures sc
        ON sc.id = cb.closure_id
    WHERE cb.id = p_closure_block_id
    FOR UPDATE OF cb, sc;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLOSURE_BLOCK_NOT_FOUND';
    END IF;

    IF v_block.reopened_at IS NOT NULL THEN
        RAISE EXCEPTION 'CLOSURE_ALREADY_REOPENED';
    END IF;

    SELECT *
    INTO v_inspection
    FROM storage_point_closure_inspections
    WHERE id = p_inspection_id
      AND closure_block_id = p_closure_block_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLOSURE_INSPECTION_NOT_FOUND';
    END IF;

    SELECT COALESCE(SUM(quantity), 0)
    INTO v_released_from_inspection
    FROM storage_point_closure_block_movements
    WHERE inspection_id = p_inspection_id
      AND movement_type = 'release';

    IF v_released_from_inspection + p_quantity >
       v_inspection.suitable_quantity THEN
        RAISE EXCEPTION 'RELEASE_EXCEEDS_INSPECTED_SUITABLE_QUANTITY';
    END IF;

    v_remaining_block_quantity :=
        v_block.initial_quantity - v_block.released_quantity;

    IF p_quantity > v_remaining_block_quantity THEN
        RAISE EXCEPTION 'RELEASE_EXCEEDS_REMAINING_CLOSURE_BLOCK';
    END IF;

    UPDATE storage_point_closure_blocks
    SET released_quantity = released_quantity + p_quantity
    WHERE id = p_closure_block_id;

    INSERT INTO storage_point_closure_block_movements (
        closure_block_id,
        movement_type,
        quantity,
        inspection_id,
        operation_key,
        reason_code,
        created_by
    )
    VALUES (
        p_closure_block_id,
        'release',
        p_quantity,
        p_inspection_id,
        p_operation_key,
        p_reason_code,
        p_user_id
    )
    RETURNING id INTO v_movement_id;

    RETURN v_movement_id;
END;
$$;