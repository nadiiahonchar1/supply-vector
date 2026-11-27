-- =========================================================
-- 1. CANONICAL CARGO BALANCE FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION get_shipment_item_physical_cargo_balance(
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
  responsibility_transferred_quantity BIGINT,
  unresolved_quantity BIGINT,
  remaining_to_load BIGINT
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    si.planned_quantity::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'load'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'unload_before_departure'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'receive'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'return'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'loss'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'writeoff'
      ),
      0
    )::BIGINT,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'responsibility_transfer'
      ),
      0
    )::BIGINT,

    (
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'load'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'unload_before_departure'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'receive'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'return'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'loss'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'writeoff'
        ),
        0
      )
    )::BIGINT,

    (
      si.planned_quantity
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'load'
        ),
        0
      )
    )::BIGINT

  FROM shipment_items si

  LEFT JOIN shipment_cargo_operations co
    ON co.shipment_item_id = si.id

  WHERE si.id = p_shipment_item_id

  GROUP BY
    si.id,
    si.planned_quantity;
$$;


-- =========================================================
-- 2. ASSERT PHYSICAL CARGO BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_item_cargo_balance(
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
  FROM get_shipment_item_physical_cargo_balance(
    p_shipment_item_id
  );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
  END IF;

  IF v_balance.loaded_quantity > v_balance.planned_quantity THEN
    RAISE EXCEPTION 'LOADED_QUANTITY_EXCEEDS_PLANNED';
  END IF;

  IF v_balance.unloaded_before_departure_quantity
     > v_balance.loaded_quantity THEN
    RAISE EXCEPTION 'UNLOADED_QUANTITY_EXCEEDS_LOADED';
  END IF;

  IF v_balance.unresolved_quantity < 0 THEN
    RAISE EXCEPTION 'NEGATIVE_UNRESOLVED_CARGO_BALANCE';
  END IF;

  IF v_balance.remaining_to_load < 0 THEN
    RAISE EXCEPTION 'NEGATIVE_REMAINING_TO_LOAD';
  END IF;
END;
$$;


-- =========================================================
-- 3. VALIDATE CARGO OPERATION CAPACITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_cargo_operation_capacity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_loaded BIGINT;
  v_unloaded BIGINT;
  v_received BIGINT;
  v_returned BIGINT;
  v_lost BIGINT;
  v_written_off BIGINT;
  v_unresolved BIGINT;
  v_trip_status TEXT;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'CARGO_OPERATIONS_ARE_IMMUTABLE';
  END IF;

  SELECT
    si.id,
    si.planned_quantity,
    si.shipment_id,
    s.status AS shipment_status,
    s.trip_id
  INTO v_item
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE si.id = NEW.shipment_item_id
  FOR UPDATE OF si, s;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
  END IF;

  IF v_item.trip_id IS NULL THEN
    RAISE EXCEPTION 'SHIPMENT_NOT_ASSIGNED_TO_TRIP';
  END IF;

  SELECT status
  INTO v_trip_status
  FROM trips
  WHERE id = v_item.trip_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRIP_NOT_FOUND';
  END IF;

  SELECT
    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'load'
      ),
      0
    ),

    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'unload_before_departure'
      ),
      0
    ),

    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'receive'
      ),
      0
    ),

    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'return'
      ),
      0
    ),

    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'loss'
      ),
      0
    ),

    COALESCE(
      SUM(quantity) FILTER (
        WHERE operation_type = 'writeoff'
      ),
      0
    )

  INTO
    v_loaded,
    v_unloaded,
    v_received,
    v_returned,
    v_lost,
    v_written_off

  FROM shipment_cargo_operations
  WHERE shipment_item_id = NEW.shipment_item_id;

  v_unresolved :=
    v_loaded
    - v_unloaded
    - v_received
    - v_returned
    - v_lost
    - v_written_off;

  IF v_unresolved < 0 THEN
    RAISE EXCEPTION 'NEGATIVE_UNRESOLVED_CARGO_BALANCE';
  END IF;


  -- -------------------------------------------------------
  -- Physical loading
  -- -------------------------------------------------------

  IF NEW.operation_type = 'load' THEN

    IF v_item.shipment_status <> 'pending' THEN
      RAISE EXCEPTION 'SHIPMENT_NOT_PENDING';
    END IF;

    IF v_trip_status NOT IN ('planned', 'ready') THEN
      RAISE EXCEPTION 'TRIP_NOT_AVAILABLE_FOR_LOADING';
    END IF;

    IF v_loaded + NEW.quantity > v_item.planned_quantity THEN
      RAISE EXCEPTION 'LOADING_EXCEEDS_PLANNED_QUANTITY';
    END IF;

  END IF;


  -- -------------------------------------------------------
  -- Unloading before departure
  -- -------------------------------------------------------

  IF NEW.operation_type = 'unload_before_departure' THEN

    IF v_item.shipment_status <> 'pending' THEN
      RAISE EXCEPTION 'SHIPMENT_NOT_PENDING';
    END IF;

    IF v_trip_status NOT IN ('planned', 'ready') THEN
      RAISE EXCEPTION 'TRIP_ALREADY_DEPARTED';
    END IF;

    IF v_unloaded + NEW.quantity > v_loaded THEN
      RAISE EXCEPTION 'UNLOADING_EXCEEDS_LOADED_QUANTITY';
    END IF;

  END IF;


  -- -------------------------------------------------------
  -- Physical receipt
  -- -------------------------------------------------------

  IF NEW.operation_type = 'receive' THEN

    IF v_item.shipment_status <> 'in_transit' THEN
      RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
    END IF;

    IF v_trip_status NOT IN ('in_transit', 'delivered') THEN
      RAISE EXCEPTION 'TRIP_NOT_IN_TRANSIT';
    END IF;

    IF NEW.quantity > v_unresolved THEN
      RAISE EXCEPTION 'RECEIPT_EXCEEDS_UNRESOLVED_CARGO';
    END IF;

  END IF;


  -- -------------------------------------------------------
  -- Physical return, loss, and write-off
  -- -------------------------------------------------------

  IF NEW.operation_type IN (
    'return',
    'loss',
    'writeoff'
  ) THEN

    IF v_item.shipment_status <> 'in_transit' THEN
      RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
    END IF;

    IF v_trip_status NOT IN ('in_transit', 'delivered') THEN
      RAISE EXCEPTION 'TRIP_NOT_IN_TRANSIT';
    END IF;

    IF NEW.quantity > v_unresolved THEN
      RAISE EXCEPTION 'RESOLUTION_EXCEEDS_UNRESOLVED_CARGO';
    END IF;

  END IF;


  -- -------------------------------------------------------
  -- Transfer of responsibility
  -- -------------------------------------------------------

  IF NEW.operation_type = 'responsibility_transfer' THEN

    IF v_item.shipment_status <> 'in_transit' THEN
      RAISE EXCEPTION 'SHIPMENT_NOT_IN_TRANSIT';
    END IF;

    IF v_trip_status NOT IN ('in_transit', 'delivered') THEN
      RAISE EXCEPTION 'TRIP_NOT_IN_TRANSIT';
    END IF;

    IF NEW.quantity > v_unresolved THEN
      RAISE EXCEPTION 'TRANSFER_EXCEEDS_UNRESOLVED_CARGO';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS shipment_cargo_operation_capacity_guard
ON shipment_cargo_operations;

CREATE TRIGGER shipment_cargo_operation_capacity_guard
BEFORE INSERT
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_cargo_operation_capacity();


-- =========================================================
-- 4. PREVENT CARGO OPERATION MUTATION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_cargo_operation_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'CARGO_OPERATIONS_ARE_IMMUTABLE';
END;
$$;

DROP TRIGGER IF EXISTS shipment_cargo_operations_immutable
ON shipment_cargo_operations;

CREATE TRIGGER shipment_cargo_operations_immutable
BEFORE UPDATE OR DELETE
ON shipment_cargo_operations
FOR EACH ROW
EXECUTE FUNCTION prevent_cargo_operation_mutation();


-- =========================================================
-- 5. PREVENT SHIPMENT ITEM CHANGES AFTER PHYSICAL ACTIVITY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_shipment_item_physical_history_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.shipment_id IS DISTINCT FROM OLD.shipment_id
     OR NEW.transfer_request_source_id
        IS DISTINCT FROM OLD.transfer_request_source_id
     OR NEW.product_id IS DISTINCT FROM OLD.product_id
     OR NEW.planned_quantity
        IS DISTINCT FROM OLD.planned_quantity THEN

    IF EXISTS (
      SELECT 1
      FROM shipment_cargo_operations
      WHERE shipment_item_id = OLD.id
    ) THEN
      RAISE EXCEPTION 'SHIPMENT_ITEM_HAS_PHYSICAL_HISTORY';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS shipment_item_physical_history_guard
ON shipment_items;

CREATE TRIGGER shipment_item_physical_history_guard
BEFORE UPDATE
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION prevent_shipment_item_physical_history_change();


-- =========================================================
-- 6. VALIDATE ALL SHIPMENT ITEMS
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_cargo_integrity(
  p_shipment_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM shipments
    WHERE id = p_shipment_id
  ) THEN
    RAISE EXCEPTION 'SHIPMENT_NOT_FOUND';
  END IF;

  FOR v_item IN
    SELECT id
    FROM shipment_items
    WHERE shipment_id = p_shipment_id
    ORDER BY id
    FOR UPDATE
  LOOP
    PERFORM assert_shipment_item_cargo_balance(
      v_item.id
    );
  END LOOP;
END;
$$;


-- =========================================================
-- 7. VALIDATE TRIP CARGO BEFORE COMPLETION
-- =========================================================

CREATE OR REPLACE FUNCTION validate_trip_cargo_before_completion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_balance RECORD;
BEGIN
  IF NEW.status = 'delivered'
     AND OLD.status IS DISTINCT FROM NEW.status THEN

    FOR v_shipment IN
      SELECT id
      FROM shipments
      WHERE trip_id = NEW.id
      ORDER BY id
      FOR UPDATE
    LOOP

      PERFORM assert_shipment_cargo_integrity(
        v_shipment.id
      );

      FOR v_balance IN
        SELECT
          b.unresolved_quantity
        FROM shipment_items si
        CROSS JOIN LATERAL
          get_shipment_item_physical_cargo_balance(si.id) b
        WHERE si.shipment_id = v_shipment.id
      LOOP
        IF v_balance.unresolved_quantity > 0 THEN
          RAISE EXCEPTION 'TRIP_HAS_UNRESOLVED_PHYSICAL_CARGO';
        END IF;
      END LOOP;

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
-- 8. PREVENT LOADING AFTER TRIP DEPARTURE
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_loading_after_trip_departure()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip_status TEXT;
  v_shipment_status TEXT;
BEGIN
  SELECT
    t.status,
    s.status
  INTO
    v_trip_status,
    v_shipment_status
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  JOIN trips t
    ON t.id = s.trip_id
  WHERE si.id = NEW.shipment_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHIPMENT_ITEM_NOT_FOUND';
  END IF;

  IF v_trip_status IN ('in_transit', 'delivered', 'cancelled') THEN
    RAISE EXCEPTION 'LOADING_AFTER_TRIP_DEPARTURE_NOT_ALLOWED';
  END IF;

  IF v_shipment_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'SHIPMENT_ALREADY_TERMINAL';
  END IF;

  RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS shipment_loading_trip_departure_guard
ON shipment_cargo_operations;

CREATE TRIGGER shipment_loading_trip_departure_guard
BEFORE INSERT
ON shipment_cargo_operations
FOR EACH ROW
WHEN (NEW.operation_type = 'load')
EXECUTE FUNCTION prevent_loading_after_trip_departure();


-- =========================================================
-- 9. SHIPMENT CARGO BALANCE VIEW
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
  balance.responsibility_transferred_quantity,
  balance.unresolved_quantity,
  balance.remaining_to_load

FROM shipments s

JOIN shipment_items si
  ON si.shipment_id = s.id

CROSS JOIN LATERAL
  get_shipment_item_physical_cargo_balance(si.id) balance;