-- =========================================================
-- 1. OPERATION METADATA AND IDEMPOTENCY
-- =========================================================

ALTER TABLE inventory_blocks
    ADD COLUMN IF NOT EXISTS comment TEXT,
    ADD COLUMN IF NOT EXISTS operation_key UUID;

ALTER TABLE inventory_block_movements
    ADD COLUMN IF NOT EXISTS operation_key UUID;

ALTER TABLE inventory_movements
    ADD COLUMN IF NOT EXISTS operation_key UUID,
    ADD COLUMN IF NOT EXISTS accounting_act_number TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_blocks_operation_key
    ON inventory_blocks(operation_key)
    WHERE operation_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_block_movements_operation_key
    ON inventory_block_movements(operation_key)
    WHERE operation_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_movements_operation_key
    ON inventory_movements(operation_key)
    WHERE operation_key IS NOT NULL;


-- =========================================================
-- 2. BLOCK INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION block_inventory(
    p_inventory_id UUID,
    p_quantity INTEGER,
    p_reason TEXT,
    p_user_id UUID,
    p_operation_key UUID,
    p_reservation_releases JSONB DEFAULT '[]'::JSONB,
    p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_inventory RECORD;
    v_existing_block RECORD;
    v_release RECORD;

    v_block_id UUID;
    v_available_quantity INTEGER;
    v_required_release INTEGER;
    v_selected_release INTEGER := 0;
    v_released_quantity INTEGER := 0;
    v_release_key UUID;
BEGIN
    -- -----------------------------------------------------
    -- Basic validation
    -- -----------------------------------------------------

    IF p_inventory_id IS NULL
       OR p_quantity IS NULL
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    IF p_reason IS NULL
       OR p_reason NOT IN (
           'damage',
           'suspected_damage',
           'loss',
           'other'
       ) THEN
        RAISE EXCEPTION 'INVALID_INVENTORY_BLOCK_REASON';
    END IF;

    IF p_reason = 'other'
       AND NULLIF(BTRIM(p_comment), '') IS NULL THEN
        RAISE EXCEPTION 'INVENTORY_BLOCK_COMMENT_REQUIRED';
    END IF;

    IF p_reservation_releases IS NULL
       OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
        RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_LIST';
    END IF;


    -- -----------------------------------------------------
    -- Idempotency
    -- -----------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing_block
    FROM inventory_blocks
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing_block.inventory_id
                IS DISTINCT FROM p_inventory_id
           OR v_existing_block.initial_quantity
                IS DISTINCT FROM p_quantity
           OR v_existing_block.reason
                IS DISTINCT FROM p_reason
           OR v_existing_block.created_by
                IS DISTINCT FROM p_user_id
           OR v_existing_block.comment
                IS DISTINCT FROM p_comment THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing_block.id;
    END IF;


    -- -----------------------------------------------------
    -- Lock inventory
    -- -----------------------------------------------------

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
    END IF;

    v_available_quantity :=
        v_inventory.quantity
        - v_inventory.reserved_quantity
        - v_inventory.blocked_quantity;

    v_required_release := GREATEST(
        0,
        p_quantity - v_available_quantity
    );


    -- -----------------------------------------------------
    -- Validate reservation release entries
    -- -----------------------------------------------------

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_reservation_releases) AS entry
        WHERE
            jsonb_typeof(entry) <> 'object'
            OR NOT (entry ? 'reservation_id')
            OR NOT (entry ? 'quantity')
            OR NULLIF(entry->>'reservation_id', '') IS NULL
            OR NULLIF(entry->>'quantity', '') IS NULL
            OR entry->>'reservation_id' !~
                '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            OR entry->>'quantity' !~ '^[1-9][0-9]*$'
    ) THEN
        RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_ENTRY';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_reservation_releases) AS entry
        GROUP BY (entry->>'reservation_id')::UUID
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'DUPLICATE_RESERVATION_RELEASE';
    END IF;

    SELECT COALESCE(
        SUM((entry->>'quantity')::BIGINT),
        0
    )
    INTO v_selected_release
    FROM jsonb_array_elements(p_reservation_releases) AS entry;

    IF v_selected_release <> v_required_release THEN
        RAISE EXCEPTION 'RESERVATION_RELEASE_AMOUNT_MISMATCH';
    END IF;


    -- -----------------------------------------------------
    -- Release explicitly selected reservations
    -- -----------------------------------------------------

    FOR v_release IN
        SELECT
            (entry->>'reservation_id')::UUID AS reservation_id,
            (entry->>'quantity')::INTEGER AS quantity
        FROM jsonb_array_elements(p_reservation_releases) AS entry
        ORDER BY (entry->>'reservation_id')::UUID
    LOOP
        PERFORM 1
        FROM inventory_reservations
        WHERE id = v_release.reservation_id
          AND inventory_id = p_inventory_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'RESERVATION_DOES_NOT_BELONG_TO_INVENTORY';
        END IF;

        v_release_key := (
            SUBSTRING(
                MD5(
                    p_operation_key::TEXT
                    || ':block:'
                    || v_release.reservation_id::TEXT
                ),
                1,
                8
            )
            || '-'
            || SUBSTRING(
                MD5(
                    p_operation_key::TEXT
                    || ':block:'
                    || v_release.reservation_id::TEXT
                ),
                9,
                4
            )
            || '-'
            || SUBSTRING(
                MD5(
                    p_operation_key::TEXT
                    || ':block:'
                    || v_release.reservation_id::TEXT
                ),
                13,
                4
            )
            || '-'
            || SUBSTRING(
                MD5(
                    p_operation_key::TEXT
                    || ':block:'
                    || v_release.reservation_id::TEXT
                ),
                17,
                4
            )
            || '-'
            || SUBSTRING(
                MD5(
                    p_operation_key::TEXT
                    || ':block:'
                    || v_release.reservation_id::TEXT
                ),
                21,
                12
            )
        )::UUID;

        PERFORM release_inventory_reservation(
            v_release.reservation_id,
            v_release.quantity,
            'inventory_block',
            'inventory_block',
            p_inventory_id,
            p_user_id,
            v_release_key
        );

        v_released_quantity :=
            v_released_quantity + v_release.quantity;
    END LOOP;


    -- -----------------------------------------------------
    -- Recheck inventory after releases
    -- -----------------------------------------------------

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    v_available_quantity :=
        v_inventory.quantity
        - v_inventory.reserved_quantity
        - v_inventory.blocked_quantity;

    IF v_available_quantity < p_quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_INVENTORY';
    END IF;


    -- -----------------------------------------------------
    -- Create inventory block
    -- -----------------------------------------------------

    INSERT INTO inventory_blocks (
        inventory_id,
        reason,
        initial_quantity,
        unblocked_quantity,
        created_by,
        comment,
        operation_key
    )
    VALUES (
        p_inventory_id,
        p_reason,
        p_quantity,
        0,
        p_user_id,
        p_comment,
        p_operation_key
    )
    RETURNING id
    INTO v_block_id;

    UPDATE inventory
    SET
        blocked_quantity = blocked_quantity + p_quantity,
        updated_at = NOW()
    WHERE id = p_inventory_id;

    INSERT INTO inventory_block_movements (
        block_id,
        movement_type,
        quantity,
        reference_type,
        reference_id,
        reason,
        created_by,
        operation_key
    )
    VALUES (
        v_block_id,
        'block',
        p_quantity,
        'inventory_block',
        v_block_id,
        p_reason,
        p_user_id,
        p_operation_key
    );

    RETURN v_block_id;
END;
$$;


-- =========================================================
-- 3. UNBLOCK INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION unblock_inventory(
    p_block_id UUID,
    p_quantity INTEGER,
    p_reason TEXT,
    p_user_id UUID,
    p_operation_key UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_block RECORD;
    v_inventory RECORD;
    v_existing RECORD;

    v_remaining_quantity INTEGER;
    v_movement_id UUID;
BEGIN
    IF p_block_id IS NULL
       OR p_quantity IS NULL
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    IF p_reason IS NULL
       OR BTRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'UNBLOCK_REASON_REQUIRED';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM inventory_block_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.block_id IS DISTINCT FROM p_block_id
           OR v_existing.movement_type <> 'unblock'
           OR v_existing.quantity IS DISTINCT FROM p_quantity
           OR v_existing.reason IS DISTINCT FROM p_reason
           OR v_existing.created_by IS DISTINCT FROM p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;


    -- Lock inventory first to keep a consistent lock order.
    SELECT i.*
    INTO v_inventory
    FROM inventory_blocks b
    JOIN inventory i
        ON i.id = b.inventory_id
    WHERE b.id = p_block_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_BLOCK_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = v_inventory.id
    FOR UPDATE;

    SELECT *
    INTO v_block
    FROM inventory_blocks
    WHERE id = p_block_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_BLOCK_NOT_FOUND';
    END IF;

    v_remaining_quantity :=
        v_block.initial_quantity - v_block.unblocked_quantity;

    IF v_remaining_quantity < p_quantity THEN
        RAISE EXCEPTION 'UNBLOCK_EXCEEDS_REMAINING_BLOCK';
    END IF;

    IF v_inventory.blocked_quantity < p_quantity THEN
        RAISE EXCEPTION 'INVENTORY_BLOCKED_BALANCE_MISMATCH';
    END IF;

    UPDATE inventory_blocks
    SET
        unblocked_quantity = unblocked_quantity + p_quantity
    WHERE id = p_block_id;

    UPDATE inventory
    SET
        blocked_quantity = blocked_quantity - p_quantity,
        updated_at = NOW()
    WHERE id = v_inventory.id;

    INSERT INTO inventory_block_movements (
        block_id,
        movement_type,
        quantity,
        reference_type,
        reference_id,
        reason,
        created_by,
        operation_key
    )
    VALUES (
        p_block_id,
        'unblock',
        p_quantity,
        'inventory_block',
        p_block_id,
        p_reason,
        p_user_id,
        p_operation_key
    )
    RETURNING id
    INTO v_movement_id;

    RETURN v_movement_id;
END;
$$;


-- =========================================================
-- 4. ADJUST INVENTORY
-- =========================================================

CREATE OR REPLACE FUNCTION adjust_inventory(
    p_inventory_id UUID,
    p_actual_quantity INTEGER,
    p_reason TEXT,
    p_user_id UUID,
    p_operation_key UUID,
    p_reservation_releases JSONB DEFAULT '[]'::JSONB,
    p_accounting_act_number TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_inventory RECORD;
    v_existing RECORD;
    v_release RECORD;

    v_movement_id UUID;
    v_difference INTEGER;
    v_shortage INTEGER;
    v_available_quantity INTEGER;
    v_required_release INTEGER;
    v_selected_release BIGINT := 0;
    v_release_key UUID;
BEGIN
    -- -----------------------------------------------------
    -- Basic validation
    -- -----------------------------------------------------

    IF p_inventory_id IS NULL
       OR p_actual_quantity IS NULL
       OR p_actual_quantity < 0 THEN
        RAISE EXCEPTION 'INVALID_ACTUAL_INVENTORY_QUANTITY';
    END IF;

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACTOR_REQUIRED';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    IF p_reason IS NULL
       OR BTRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'INVENTORY_ADJUSTMENT_REASON_REQUIRED';
    END IF;

    IF p_reservation_releases IS NULL
       OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
        RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_LIST';
    END IF;


    -- -----------------------------------------------------
    -- Idempotency
    -- -----------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_operation_key::TEXT, 0)
    );

    SELECT *
    INTO v_existing
    FROM inventory_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        IF v_existing.inventory_id IS DISTINCT FROM p_inventory_id
           OR v_existing.movement_type <> 'adjustment'
           OR v_existing.quantity_after IS DISTINCT FROM p_actual_quantity
           OR v_existing.reason IS DISTINCT FROM p_reason
           OR v_existing.accounting_act_number
                IS DISTINCT FROM p_accounting_act_number
           OR v_existing.created_by IS DISTINCT FROM p_user_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED';
        END IF;

        RETURN v_existing.id;
    END IF;


    -- -----------------------------------------------------
    -- Lock inventory and calculate difference
    -- -----------------------------------------------------

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_RECORD_NOT_FOUND';
    END IF;

    v_difference :=
        p_actual_quantity - v_inventory.quantity;

    IF v_difference = 0 THEN
        RAISE EXCEPTION 'INVENTORY_ADJUSTMENT_NOT_REQUIRED';
    END IF;

    IF v_difference < 0
       AND (
           p_accounting_act_number IS NULL
           OR BTRIM(p_accounting_act_number) = ''
       ) THEN
        RAISE EXCEPTION 'ACCOUNTING_ACT_NUMBER_REQUIRED';
    END IF;


    -- -----------------------------------------------------
    -- Validate reservation releases for a shortage
    -- -----------------------------------------------------

    IF v_difference < 0 THEN
        v_shortage := ABS(v_difference);

        IF p_actual_quantity < v_inventory.blocked_quantity THEN
            RAISE EXCEPTION 'ACTUAL_QUANTITY_BELOW_BLOCKED_QUANTITY';
        END IF;

        v_available_quantity :=
            v_inventory.quantity
            - v_inventory.reserved_quantity
            - v_inventory.blocked_quantity;

        v_required_release := GREATEST(
            0,
            v_shortage - v_available_quantity
        );

        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_reservation_releases) AS entry
            WHERE
                jsonb_typeof(entry) <> 'object'
                OR NOT (entry ? 'reservation_id')
                OR NOT (entry ? 'quantity')
                OR NULLIF(entry->>'reservation_id', '') IS NULL
                OR NULLIF(entry->>'quantity', '') IS NULL
                OR entry->>'reservation_id' !~
                    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                OR entry->>'quantity' !~ '^[1-9][0-9]*$'
        ) THEN
            RAISE EXCEPTION 'INVALID_RESERVATION_RELEASE_ENTRY';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_reservation_releases) AS entry
            GROUP BY (entry->>'reservation_id')::UUID
            HAVING COUNT(*) > 1
        ) THEN
            RAISE EXCEPTION 'DUPLICATE_RESERVATION_RELEASE';
        END IF;

        SELECT COALESCE(
            SUM((entry->>'quantity')::BIGINT),
            0
        )
        INTO v_selected_release
        FROM jsonb_array_elements(p_reservation_releases) AS entry;

        IF v_selected_release <> v_required_release THEN
            RAISE EXCEPTION 'RESERVATION_RELEASE_AMOUNT_MISMATCH';
        END IF;


        -- -------------------------------------------------
        -- Release explicitly selected reservations
        -- -------------------------------------------------

        FOR v_release IN
            SELECT
                (entry->>'reservation_id')::UUID AS reservation_id,
                (entry->>'quantity')::INTEGER AS quantity
            FROM jsonb_array_elements(p_reservation_releases) AS entry
            ORDER BY (entry->>'reservation_id')::UUID
        LOOP
            PERFORM 1
            FROM inventory_reservations
            WHERE id = v_release.reservation_id
              AND inventory_id = p_inventory_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'RESERVATION_DOES_NOT_BELONG_TO_INVENTORY';
            END IF;

            v_release_key := (
                SUBSTRING(
                    MD5(
                        p_operation_key::TEXT
                        || ':adjustment:'
                        || v_release.reservation_id::TEXT
                    ),
                    1, 8
                )
                || '-'
                || SUBSTRING(
                    MD5(
                        p_operation_key::TEXT
                        || ':adjustment:'
                        || v_release.reservation_id::TEXT
                    ),
                    9, 4
                )
                || '-'
                || SUBSTRING(
                    MD5(
                        p_operation_key::TEXT
                        || ':adjustment:'
                        || v_release.reservation_id::TEXT
                    ),
                    13, 4
                )
                || '-'
                || SUBSTRING(
                    MD5(
                        p_operation_key::TEXT
                        || ':adjustment:'
                        || v_release.reservation_id::TEXT
                    ),
                    17, 4
                )
                || '-'
                || SUBSTRING(
                    MD5(
                        p_operation_key::TEXT
                        || ':adjustment:'
                        || v_release.reservation_id::TEXT
                    ),
                    21, 12
                )
            )::UUID;

            PERFORM release_inventory_reservation(
                v_release.reservation_id,
                v_release.quantity,
                'inventory_adjustment',
                'inventory',
                p_inventory_id,
                p_user_id,
                v_release_key
            );
        END LOOP;


        -- -------------------------------------------------
        -- Recheck inventory after reservation releases
        -- -------------------------------------------------

        SELECT *
        INTO v_inventory
        FROM inventory
        WHERE id = p_inventory_id
        FOR UPDATE;

        IF p_actual_quantity <
           v_inventory.reserved_quantity + v_inventory.blocked_quantity THEN
            RAISE EXCEPTION 'ACTUAL_QUANTITY_BELOW_COMMITTED_QUANTITY';
        END IF;
    ELSE
        IF jsonb_array_length(p_reservation_releases) > 0 THEN
            RAISE EXCEPTION 'UNEXPECTED_RESERVATION_RELEASES';
        END IF;
    END IF;


    -- -----------------------------------------------------
    -- Apply physical quantity adjustment
    -- -----------------------------------------------------

    UPDATE inventory
    SET
        quantity = p_actual_quantity,
        updated_at = NOW()
    WHERE id = p_inventory_id;

    INSERT INTO inventory_movements (
        inventory_id,
        movement_type,
        quantity,
        quantity_before,
        quantity_after,
        reference_type,
        reference_id,
        reason,
        accounting_act_number,
        created_by,
        operation_key
    )
    VALUES (
        p_inventory_id,
        'adjustment',
        ABS(v_difference),
        v_inventory.quantity,
        p_actual_quantity,
        'inventory_adjustment',
        p_inventory_id,
        p_reason,
        p_accounting_act_number,
        p_user_id,
        p_operation_key
    )
    RETURNING id
    INTO v_movement_id;

    RETURN v_movement_id;
END;
$$;