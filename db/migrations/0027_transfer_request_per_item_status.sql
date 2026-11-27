-- =========================================================
-- 1. CALCULATE PHYSICAL CARGO BALANCE FOR A REQUEST ITEM
-- =========================================================

CREATE OR REPLACE FUNCTION get_transfer_request_item_execution_balance(
    p_transfer_request_item_id UUID
)
RETURNS TABLE (
    requested_quantity BIGINT,
    cancelled_quantity BIGINT,
    received_quantity BIGINT,
    loaded_quantity BIGINT,
    unloaded_before_departure_quantity BIGINT,
    returned_quantity BIGINT,
    lost_quantity BIGINT,
    written_off_quantity BIGINT,
    unresolved_quantity BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        tri.requested_quantity::BIGINT,
        tri.cancelled_quantity::BIGINT,

        COALESCE(cargo.received_quantity, 0)::BIGINT,
        COALESCE(cargo.loaded_quantity, 0)::BIGINT,
        COALESCE(cargo.unloaded_quantity, 0)::BIGINT,
        COALESCE(cargo.returned_quantity, 0)::BIGINT,
        COALESCE(cargo.lost_quantity, 0)::BIGINT,
        COALESCE(cargo.written_off_quantity, 0)::BIGINT,

        (
            COALESCE(cargo.loaded_quantity, 0)
            - COALESCE(cargo.unloaded_quantity, 0)
            - COALESCE(cargo.received_quantity, 0)
            - COALESCE(cargo.returned_quantity, 0)
            - COALESCE(cargo.lost_quantity, 0)
            - COALESCE(cargo.written_off_quantity, 0)
        )::BIGINT

    FROM transfer_request_items tri

    LEFT JOIN LATERAL (
        SELECT
            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'load'
                ),
                0
            ) AS loaded_quantity,

            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'receive'
                ),
                0
            ) AS received_quantity,

            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'unload_before_departure'
                ),
                0
            ) AS unloaded_quantity,

            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'return'
                ),
                0
            ) AS returned_quantity,

            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'loss'
                ),
                0
            ) AS lost_quantity,

            COALESCE(
                SUM(sco.quantity) FILTER (
                    WHERE sco.operation_type = 'writeoff'
                ),
                0
            ) AS written_off_quantity

        FROM transfer_request_sources trs

        JOIN shipment_items si
            ON si.transfer_request_source_id = trs.id

        JOIN shipment_cargo_operations sco
            ON sco.shipment_item_id = si.id

        WHERE trs.transfer_request_item_id =
            tri.id
    ) cargo ON TRUE

    WHERE tri.id = p_transfer_request_item_id;
$$;


-- =========================================================
-- 2. VALIDATE REQUEST ITEM EXECUTION BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_item_execution_balance(
    p_transfer_request_item_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance RECORD;
BEGIN
    SELECT *
    INTO v_balance
    FROM get_transfer_request_item_execution_balance(
        p_transfer_request_item_id
    );

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_ITEM_NOT_FOUND';
    END IF;

    IF v_balance.cancelled_quantity >
       v_balance.requested_quantity THEN
        RAISE EXCEPTION 'CANCELLED_QUANTITY_EXCEEDS_REQUESTED';
    END IF;

    IF v_balance.received_quantity >
       v_balance.requested_quantity THEN
        RAISE EXCEPTION 'RECEIVED_QUANTITY_EXCEEDS_REQUESTED';
    END IF;

    IF v_balance.received_quantity
       + v_balance.cancelled_quantity
       > v_balance.requested_quantity THEN
        RAISE EXCEPTION 'COMPLETED_QUANTITY_EXCEEDS_REQUESTED';
    END IF;

    IF v_balance.unresolved_quantity < 0 THEN
        RAISE EXCEPTION 'NEGATIVE_UNRESOLVED_CARGO_BALANCE';
    END IF;
END;
$$;


-- =========================================================
-- 3. RECALCULATE TRANSFER REQUEST STATUS
-- =========================================================

CREATE OR REPLACE FUNCTION recalculate_transfer_request_status(
    p_transfer_request_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_request RECORD;

    v_item_count INTEGER;
    v_total_received BIGINT;
    v_total_cancelled BIGINT;

    v_all_items_complete BOOLEAN;
    v_has_unresolved_cargo BOOLEAN;

    v_new_status TEXT;
BEGIN
    SELECT *
    INTO v_request
    FROM transfer_requests
    WHERE id = p_transfer_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status IN (
        'fulfilled',
        'partially_fulfilled',
        'cancelled'
    ) THEN
        RETURN v_request.status;
    END IF;

    IF v_request.status IN ('draft', 'pending') THEN
        RETURN v_request.status;
    END IF;

    SELECT
        COUNT(*)::INTEGER,

        COALESCE(
            SUM(balance.received_quantity),
            0
        ),

        COALESCE(
            SUM(balance.cancelled_quantity),
            0
        ),

        COALESCE(
            BOOL_AND(
                balance.received_quantity
                + balance.cancelled_quantity
                = balance.requested_quantity
            ),
            FALSE
        ),

        COALESCE(
            BOOL_OR(balance.unresolved_quantity > 0),
            FALSE
        )

    INTO
        v_item_count,
        v_total_received,
        v_total_cancelled,
        v_all_items_complete,
        v_has_unresolved_cargo

    FROM transfer_request_items tri

    CROSS JOIN LATERAL
        get_transfer_request_item_execution_balance(tri.id)
        balance

    WHERE tri.transfer_request_id = p_transfer_request_id;

    IF v_item_count = 0 THEN
        RAISE EXCEPTION 'TRANSFER_REQUEST_HAS_NO_ITEMS';
    END IF;

    FOR v_request IN
        SELECT tri.id
        FROM transfer_request_items tri
        WHERE tri.transfer_request_id = p_transfer_request_id
    LOOP
        PERFORM validate_transfer_request_item_execution_balance(
            v_request.id
        );
    END LOOP;

    IF v_all_items_complete THEN

        IF v_total_received = 0 THEN
            v_new_status := 'cancelled';

        ELSIF v_total_cancelled > 0 THEN
            v_new_status := 'partially_fulfilled';

        ELSE
            v_new_status := 'fulfilled';
        END IF;

    ELSIF v_has_unresolved_cargo THEN

        v_new_status := 'in_progress';

    ELSIF v_total_received > 0 THEN

        v_new_status := 'in_progress';

    ELSE

        v_new_status := 'approved';

    END IF;

    IF v_new_status IS DISTINCT FROM (
        SELECT status
        FROM transfer_requests
        WHERE id = p_transfer_request_id
    ) THEN

        UPDATE transfer_requests
        SET
            status = v_new_status,

            completed_at =
                CASE
                    WHEN v_new_status IN (
                        'fulfilled',
                        'partially_fulfilled'
                    )
                    THEN NOW()
                    ELSE NULL
                END,

            cancelled_at =
                CASE
                    WHEN v_new_status = 'cancelled'
                    THEN NOW()
                    ELSE NULL
                END,

            updated_at = NOW()

        WHERE id = p_transfer_request_id;

    END IF;

    RETURN v_new_status;
END;
$$;


-- =========================================================
-- 4. RECALCULATE AFTER CARGO OPERATIONS
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_cargo_operation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_id UUID;
BEGIN
    SELECT trs.transfer_request_id
    INTO v_request_id
    FROM shipment_items si
    JOIN transfer_request_sources trs
        ON trs.id = si.transfer_request_source_id
    WHERE si.id = NEW.shipment_item_id;

    IF v_request_id IS NOT NULL THEN
        PERFORM recalculate_transfer_request_status(
            v_request_id
        );
    END IF;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS
    recalculate_request_after_cargo_operation
ON shipment_cargo_operations;

CREATE TRIGGER recalculate_request_after_cargo_operation
AFTER INSERT
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION trigger_recalculate_request_after_cargo_operation();


-- =========================================================
-- 5. RECALCULATE AFTER REQUEST ITEM QUANTITY CHANGES
-- =========================================================

CREATE OR REPLACE FUNCTION trigger_recalculate_request_after_item_quantity_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM recalculate_transfer_request_status(
        NEW.transfer_request_id
    );

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS
    transfer_request_recalculate_after_cancellation
ON transfer_request_items;

DROP TRIGGER IF EXISTS
    transfer_request_recalculate_after_quantity_change
ON transfer_request_items;

DROP TRIGGER IF EXISTS
    recalculate_request_after_item_quantity_change
ON transfer_request_items;

CREATE TRIGGER recalculate_request_after_item_quantity_change
AFTER UPDATE OF requested_quantity, cancelled_quantity
ON transfer_request_items
FOR EACH ROW
WHEN (
    OLD.requested_quantity IS DISTINCT FROM NEW.requested_quantity
    OR OLD.cancelled_quantity IS DISTINCT FROM NEW.cancelled_quantity
)
EXECUTE FUNCTION trigger_recalculate_request_after_item_quantity_change();


-- =========================================================
-- 6. REMOVE OBSOLETE MOVEMENT-BASED RECALCULATION TRIGGERS
-- =========================================================

DROP TRIGGER IF EXISTS
    transfer_request_recalculate_after_receipt
ON shipment_receipt_movements;

DROP TRIGGER IF EXISTS
    transfer_request_recalculate_after_loading
ON shipment_loading_movements;

DROP TRIGGER IF EXISTS
    recalculate_request_after_receipt
ON shipment_receipt_movements;

DROP TRIGGER IF EXISTS
    recalculate_request_after_loading
ON shipment_loading_movements;