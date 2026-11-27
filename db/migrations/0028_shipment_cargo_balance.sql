-- =========================================================
-- 1. SINGLE SOURCE OF TRUTH FOR SHIPMENT CARGO BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION get_shipment_item_cargo_balance(
    p_shipment_item_id UUID
)
RETURNS TABLE (
    planned_quantity BIGINT,
    loaded_quantity BIGINT,
    unloaded_before_departure_quantity BIGINT,
    received_quantity BIGINT,
    returned_quantity BIGINT,
    lost_quantity BIGINT,
    written_off_quantity BIGINT,
    transferred_quantity BIGINT,
    unresolved_quantity BIGINT,
    remaining_to_load BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        si.planned_quantity::BIGINT,

        COALESCE(cargo.loaded_quantity, 0)::BIGINT,

        COALESCE(cargo.unloaded_quantity, 0)::BIGINT,

        COALESCE(cargo.received_quantity, 0)::BIGINT,

        COALESCE(cargo.returned_quantity, 0)::BIGINT,

        COALESCE(cargo.lost_quantity, 0)::BIGINT,

        COALESCE(cargo.written_off_quantity, 0)::BIGINT,

        COALESCE(cargo.transferred_quantity, 0)::BIGINT,

        (
            COALESCE(cargo.loaded_quantity, 0)
            - COALESCE(cargo.unloaded_quantity, 0)
            - COALESCE(cargo.received_quantity, 0)
            - COALESCE(cargo.returned_quantity, 0)
            - COALESCE(cargo.lost_quantity, 0)
            - COALESCE(cargo.written_off_quantity, 0)
        )::BIGINT,

        (
            si.planned_quantity
            - COALESCE(cargo.loaded_quantity, 0)
            + COALESCE(cargo.unloaded_quantity, 0)
        )::BIGINT

    FROM shipment_items si

    LEFT JOIN LATERAL (
        SELECT
            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'load'
                ),
                0
            ) AS loaded_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'unload_before_departure'
                ),
                0
            ) AS unloaded_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'receive'
                ),
                0
            ) AS received_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'return'
                ),
                0
            ) AS returned_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'loss'
                ),
                0
            ) AS lost_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'writeoff'
                ),
                0
            ) AS written_off_quantity,

            COALESCE(
                SUM(quantity) FILTER (
                    WHERE operation_type = 'responsibility_transfer'
                ),
                0
            ) AS transferred_quantity

        FROM shipment_cargo_operations
        WHERE shipment_item_id = si.id
    ) cargo ON TRUE

    WHERE si.id = p_shipment_item_id;
$$;


-- =========================================================
-- 2. VALIDATE SHIPMENT CARGO BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_item_cargo_balance(
    p_shipment_item_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance RECORD;
BEGIN
    SELECT *
    INTO v_balance
    FROM get_shipment_item_cargo_balance(
        p_shipment_item_id
    );

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
    END IF;

    IF v_balance.loaded_quantity
       > v_balance.planned_quantity
          + v_balance.unloaded_before_departure_quantity THEN
        RAISE EXCEPTION 'LOADED_QUANTITY_EXCEEDS_PLAN';
    END IF;

    IF v_balance.unloaded_before_departure_quantity
       > v_balance.loaded_quantity THEN
        RAISE EXCEPTION 'UNLOADED_QUANTITY_EXCEEDS_LOADED';
    END IF;

    IF (
        v_balance.received_quantity
        + v_balance.returned_quantity
        + v_balance.lost_quantity
        + v_balance.written_off_quantity
    ) > (
        v_balance.loaded_quantity
        - v_balance.unloaded_before_departure_quantity
    ) THEN
        RAISE EXCEPTION 'CARGO_RESOLUTION_EXCEEDS_LOADED_BALANCE';
    END IF;

    IF v_balance.unresolved_quantity < 0 THEN
        RAISE EXCEPTION 'NEGATIVE_UNRESOLVED_CARGO_BALANCE';
    END IF;

    IF v_balance.remaining_to_load < 0 THEN
        RAISE EXCEPTION 'NEGATIVE_REMAINING_LOADING_CAPACITY';
    END IF;
END;
$$;


-- =========================================================
-- 3. ASSERT ALL SHIPMENT ITEMS ARE PHYSICALLY RESOLVED
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_cargo_resolved(
    p_shipment_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_balance RECORD;
BEGIN
    FOR v_item IN
        SELECT id
        FROM shipment_items
        WHERE shipment_id = p_shipment_id
        ORDER BY id
    LOOP
        PERFORM validate_shipment_item_cargo_balance(
            v_item.id
        );

        SELECT *
        INTO v_balance
        FROM get_shipment_item_cargo_balance(
            v_item.id
        );

        IF v_balance.unresolved_quantity > 0 THEN
            RAISE EXCEPTION 'SHIPMENT_HAS_UNRESOLVED_CARGO';
        END IF;
    END LOOP;
END;
$$;


-- =========================================================
-- 4. VALIDATE CARGO OPERATIONS BEFORE INSERT
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_cargo_operation_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_item RECORD;
    v_balance RECORD;

    v_net_loaded BIGINT;
    v_unresolved BIGINT;
BEGIN
    SELECT
        si.id,
        si.planned_quantity,
        si.shipment_id,
        s.status AS shipment_status
    INTO v_item
    FROM shipment_items si
    JOIN shipments s
        ON s.id = si.shipment_id
    WHERE si.id = NEW.shipment_item_id
    FOR UPDATE OF si, s;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
    END IF;

    SELECT *
    INTO v_balance
    FROM get_shipment_item_cargo_balance(
        NEW.shipment_item_id
    );

    v_net_loaded :=
        v_balance.loaded_quantity
        - v_balance.unloaded_before_departure_quantity;

    v_unresolved := v_balance.unresolved_quantity;

    CASE NEW.operation_type

        WHEN 'load' THEN

            IF v_item.shipment_status <> 'pending' THEN
                RAISE EXCEPTION 'SHIPMENT_NOT_LOADABLE';
            END IF;

            IF v_balance.remaining_to_load < NEW.quantity THEN
                RAISE EXCEPTION 'LOADING_EXCEEDS_PLANNED_QUANTITY';
            END IF;

        WHEN 'unload_before_departure' THEN

            IF v_item.shipment_status <> 'pending' THEN
                RAISE EXCEPTION 'SHIPMENT_ALREADY_DEPARTED';
            END IF;

            IF v_unresolved < NEW.quantity THEN
                RAISE EXCEPTION 'UNLOAD_EXCEEDS_UNRESOLVED_CARGO';
            END IF;

        WHEN 'receive' THEN

            IF v_item.shipment_status <> 'in_transit' THEN
                RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
            END IF;

            IF v_unresolved < NEW.quantity THEN
                RAISE EXCEPTION 'RECEIPT_EXCEEDS_UNRESOLVED_CARGO';
            END IF;

        WHEN 'return', 'loss', 'writeoff' THEN

            IF v_item.shipment_status <> 'in_transit' THEN
                RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
            END IF;

            IF v_unresolved < NEW.quantity THEN
                RAISE EXCEPTION 'RESOLUTION_EXCEEDS_UNRESOLVED_CARGO';
            END IF;

        WHEN 'responsibility_transfer' THEN

            IF v_item.shipment_status <> 'in_transit' THEN
                RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
            END IF;

            IF v_unresolved < NEW.quantity THEN
                RAISE EXCEPTION 'TRANSFER_EXCEEDS_UNRESOLVED_CARGO';
            END IF;

        ELSE

            RAISE EXCEPTION 'UNSUPPORTED_CARGO_OPERATION';

    END CASE;

    RETURN NEW;
END;
$$;


CREATE TRIGGER trg_validate_shipment_cargo_operation_balance
BEFORE INSERT
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_cargo_operation_balance();


-- =========================================================
-- 5. TRIP COMPLETION CARGO GUARD
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_cargo_before_completion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_shipment RECORD;
BEGIN
    IF NEW.status = 'delivered'
       AND OLD.status IS DISTINCT FROM NEW.status THEN

        FOR v_shipment IN
            SELECT id
            FROM shipments
            WHERE trip_id = NEW.id
            ORDER BY id
        LOOP
            PERFORM assert_shipment_cargo_resolved(
                v_shipment.id
            );
        END LOOP;

    END IF;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS trip_cargo_completion_guard
ON trips;

CREATE TRIGGER trip_cargo_completion_guard
BEFORE UPDATE OF status
ON trips
FOR EACH ROW
EXECUTE FUNCTION validate_trip_cargo_before_completion();


-- =========================================================
-- 6. SHIPMENT CARGO BALANCE VIEW
-- =========================================================

CREATE OR REPLACE VIEW v_shipment_cargo_balance AS
SELECT
    s.id AS shipment_id,
    s.shipment_number,
    s.status AS shipment_status,

    si.id AS shipment_item_id,
    si.product_id,
    si.planned_quantity,

    balance.loaded_quantity,
    balance.unloaded_before_departure_quantity,
    balance.received_quantity,
    balance.returned_quantity,
    balance.lost_quantity,
    balance.written_off_quantity,
    balance.transferred_quantity,
    balance.unresolved_quantity,
    balance.remaining_to_load

FROM shipments s

JOIN shipment_items si
    ON si.shipment_id = s.id

CROSS JOIN LATERAL
    get_shipment_item_cargo_balance(si.id) balance;