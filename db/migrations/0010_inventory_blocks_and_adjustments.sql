-- =========================================================
-- 1. IDEMPOTENCY KEYS
-- =========================================================

ALTER TABLE inventory_block_movements
ADD COLUMN operation_key UUID;

CREATE UNIQUE INDEX idx_inventory_block_movements_operation_key
    ON inventory_block_movements(operation_key)
    WHERE operation_key IS NOT NULL;

ALTER TABLE inventory_movements
ADD COLUMN operation_key UUID;

CREATE UNIQUE INDEX idx_inventory_movements_operation_key
    ON inventory_movements(operation_key)
    WHERE operation_key IS NOT NULL;

ALTER TABLE inventory_movements
ADD COLUMN accounting_act_number TEXT;


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
    v_block_id UUID;

    v_available_quantity INTEGER;
    v_required_release INTEGER;
    v_selected_release INTEGER;

    v_release RECORD;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Block quantity must be positive';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    IF p_reason NOT IN (
        'damage',
        'suspected_damage',
        'loss',
        'other'
    ) THEN
        RAISE EXCEPTION 'Invalid inventory block reason';
    END IF;

    IF p_reason = 'other'
       AND (
           p_comment IS NULL
           OR length(trim(p_comment)) = 0
       ) THEN
        RAISE EXCEPTION
            'Comment is required when block reason is other';
    END IF;

    IF p_reservation_releases IS NULL
       OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
        RAISE EXCEPTION
            'Reservation releases must be a JSON array';
    END IF;

    SELECT id
    INTO v_block_id
    FROM inventory_blocks
    WHERE id IN (
        SELECT reference_id
        FROM inventory_block_movements
        WHERE operation_key = p_operation_key
          AND reference_type = 'inventory_block'
    );

    IF FOUND THEN
        RETURN v_block_id;
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
    END IF;

    v_available_quantity :=
        v_inventory.quantity
        - v_inventory.reserved_quantity
        - v_inventory.blocked_quantity;

    v_required_release :=
        GREATEST(0, p_quantity - v_available_quantity);

    SELECT COALESCE(SUM((item->>'quantity')::INTEGER), 0)
    INTO v_selected_release
    FROM jsonb_array_elements(p_reservation_releases) AS item;

    IF v_selected_release <> v_required_release THEN
        RAISE EXCEPTION
            'Explicit reservation releases must equal %. Received: %',
            v_required_release,
            v_selected_release;
    END IF;

    FOR v_release IN
        SELECT
            (item->>'reservation_id')::UUID AS reservation_id,
            (item->>'quantity')::INTEGER AS quantity
        FROM jsonb_array_elements(p_reservation_releases) AS item
    LOOP
        IF v_release.quantity IS NULL OR v_release.quantity <= 0 THEN
            RAISE EXCEPTION
                'Reservation release quantity must be positive';
        END IF;

        PERFORM release_inventory_reservation(
            v_release.reservation_id,
            v_release.quantity,
            'Explicit release to allow inventory blocking',
            'inventory_block',
            NULL,
            p_user_id,
            gen_random_uuid()
        );
    END LOOP;

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
        RAISE EXCEPTION
            'Insufficient available quantity for blocking';
    END IF;

    INSERT INTO inventory_blocks (
        inventory_id,
        reason,
        initial_quantity,
        unblocked_quantity,
        created_by
    )
    VALUES (
        p_inventory_id,
        p_reason,
        p_quantity,
        0,
        p_user_id
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
        COALESCE(p_comment, p_reason),
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

    v_remaining_blocked INTEGER;
    v_movement_id UUID;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Unblock quantity must be positive';
    END IF;

    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'Unblock reason is required';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    SELECT id
    INTO v_movement_id
    FROM inventory_block_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_movement_id;
    END IF;

    SELECT *
    INTO v_block
    FROM inventory_blocks
    WHERE id = p_block_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory block not found';
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = v_block.inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
    END IF;

    v_remaining_blocked :=
        v_block.initial_quantity - v_block.unblocked_quantity;

    IF p_quantity > v_remaining_blocked THEN
        RAISE EXCEPTION
            'Unblock quantity exceeds remaining blocked quantity. Remaining: %, requested: %',
            v_remaining_blocked,
            p_quantity;
    END IF;

    IF v_inventory.blocked_quantity < p_quantity THEN
        RAISE EXCEPTION
            'Inventory blocked balance is inconsistent';
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
-- 4. ADJUST INVENTORY AFTER PHYSICAL INSPECTION
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

    v_difference INTEGER;
    v_shortage INTEGER;
    v_available_quantity INTEGER;

    v_required_release INTEGER;
    v_selected_release INTEGER;

    v_release RECORD;
    v_movement_id UUID;
BEGIN
    IF p_actual_quantity IS NULL OR p_actual_quantity < 0 THEN
        RAISE EXCEPTION
            'Actual inventory quantity cannot be negative';
    END IF;

    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'Adjustment reason is required';
    END IF;

    IF p_operation_key IS NULL THEN
        RAISE EXCEPTION 'Operation key is required';
    END IF;

    IF p_reservation_releases IS NULL
       OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
        RAISE EXCEPTION
            'Reservation releases must be a JSON array';
    END IF;

    SELECT id
    INTO v_movement_id
    FROM inventory_movements
    WHERE operation_key = p_operation_key;

    IF FOUND THEN
        RETURN v_movement_id;
    END IF;

    SELECT *
    INTO v_inventory
    FROM inventory
    WHERE id = p_inventory_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory record not found';
    END IF;

    v_difference :=
        p_actual_quantity - v_inventory.quantity;

    IF v_difference = 0 THEN
        RAISE EXCEPTION
            'Actual quantity matches current inventory. No adjustment is required';
    END IF;

    IF v_difference < 0 THEN
        v_shortage := ABS(v_difference);

        v_available_quantity :=
            v_inventory.quantity
            - v_inventory.reserved_quantity
            - v_inventory.blocked_quantity;

        v_required_release :=
            GREATEST(0, v_shortage - v_available_quantity);

        SELECT COALESCE(SUM((item->>'quantity')::INTEGER), 0)
        INTO v_selected_release
        FROM jsonb_array_elements(p_reservation_releases) AS item;

        IF v_selected_release <> v_required_release THEN
            RAISE EXCEPTION
                'Explicit reservation releases must equal %. Received: %',
                v_required_release,
                v_selected_release;
        END IF;

        FOR v_release IN
            SELECT
                (item->>'reservation_id')::UUID AS reservation_id,
                (item->>'quantity')::INTEGER AS quantity
            FROM jsonb_array_elements(p_reservation_releases) AS item
        LOOP
            IF v_release.quantity IS NULL OR v_release.quantity <= 0 THEN
                RAISE EXCEPTION
                    'Reservation release quantity must be positive';
            END IF;

            PERFORM release_inventory_reservation(
                v_release.reservation_id,
                v_release.quantity,
                'Explicit release after inventory discrepancy',
                'inventory_adjustment',
                NULL,
                p_user_id,
                gen_random_uuid()
            );
        END LOOP;

        -- Refresh balances after explicit releases.
        SELECT *
        INTO v_inventory
        FROM inventory
        WHERE id = p_inventory_id
        FOR UPDATE;

        IF p_actual_quantity <
            v_inventory.reserved_quantity + v_inventory.blocked_quantity THEN
            RAISE EXCEPTION
                'Actual quantity is insufficient to cover remaining reservations and blocked stock';
        END IF;

        IF p_accounting_act_number IS NULL
           OR length(trim(p_accounting_act_number)) = 0 THEN
            RAISE EXCEPTION
                'Accounting act number is required for a negative adjustment';
        END IF;
    END IF;

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