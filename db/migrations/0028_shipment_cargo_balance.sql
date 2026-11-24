-- =========================================================
-- 1. FUNCTION FOR CALCULATING THE ACTUAL CARGO BALANCE
-- =========================================================

CREATE OR REPLACE FUNCTION get_shipment_item_cargo_balance(
  p_shipment_item_id UUID
)
RETURNS TABLE (
  planned_quantity BIGINT,
  loaded_quantity BIGINT,
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

    COALESCE(loading.total, 0)::BIGINT,

    COALESCE(receiving.total, 0)::BIGINT,

    COALESCE(cargo.returned, 0)::BIGINT,

    COALESCE(cargo.lost, 0)::BIGINT,

    COALESCE(cargo.written_off, 0)::BIGINT,

    COALESCE(cargo.transferred, 0)::BIGINT,

    (
      COALESCE(loading.total, 0)
      - COALESCE(receiving.total, 0)
      - COALESCE(cargo.returned, 0)
      - COALESCE(cargo.lost, 0)
      - COALESCE(cargo.written_off, 0)
    )::BIGINT,

    (
      si.planned_quantity
      - COALESCE(loading.total, 0)
    )::BIGINT

  FROM shipment_items si

  LEFT JOIN LATERAL (
    SELECT SUM(quantity) AS total
    FROM shipment_loading_movements
    WHERE shipment_item_id = si.id
  ) loading ON TRUE

  LEFT JOIN LATERAL (
    SELECT SUM(quantity) AS total
    FROM shipment_receipt_movements
    WHERE shipment_item_id = si.id
  ) receiving ON TRUE

  LEFT JOIN LATERAL (
    SELECT
      SUM(quantity) FILTER (
        WHERE movement_type = 'return'
      ) AS returned,

      SUM(quantity) FILTER (
        WHERE movement_type = 'loss'
      ) AS lost,

      SUM(quantity) FILTER (
        WHERE movement_type = 'writeoff'
      ) AS written_off,

      SUM(quantity) FILTER (
        WHERE movement_type = 'responsibility_transfer'
      ) AS transferred

    FROM shipment_cargo_movements
    WHERE shipment_item_id = si.id
  ) cargo ON TRUE

  WHERE si.id = p_shipment_item_id;
$$;


-- =========================================================
-- 2. VERIFICATION OF CARGO INTEGRITY
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
  FROM get_shipment_item_cargo_balance(p_shipment_item_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію відправлення не знайдено';
  END IF;

  IF v_balance.loaded_quantity > v_balance.planned_quantity THEN
    RAISE EXCEPTION
      'Завантажена кількість перевищує заплановану';
  END IF;

  IF v_balance.received_quantity
     + v_balance.returned_quantity
     + v_balance.lost_quantity
     + v_balance.written_off_quantity
     > v_balance.loaded_quantity THEN
    RAISE EXCEPTION
      'Підтверджена доля вантажу перевищує завантажену кількість';
  END IF;

  IF v_balance.unresolved_quantity < 0 THEN
    RAISE EXCEPTION
      'Баланс вантажу не може бути від’ємним';
  END IF;
END;
$$;


-- =========================================================
-- 3. REVIEW BEFORE FINALIZING SHIPMENT
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_cargo_resolved(
  p_shipment_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_unresolved BIGINT;
BEGIN
  FOR v_item IN
    SELECT id
    FROM shipment_items
    WHERE shipment_id = p_shipment_id
  LOOP
    PERFORM validate_shipment_item_cargo_balance(v_item.id);

    SELECT unresolved_quantity
    INTO v_unresolved
    FROM get_shipment_item_cargo_balance(v_item.id);

    IF v_unresolved > 0 THEN
      RAISE EXCEPTION
        'Відправлення не можна завершити: залишився вантаж із невизначеною долею';
    END IF;
  END LOOP;
END;
$$;


-- =========================================================
-- 4. PREVENTING TRIP CLOSURE WITH UNRESOLVED CARGO
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
    LOOP
      PERFORM assert_shipment_cargo_resolved(
        v_shipment.id
      );
    END LOOP;

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trip_cargo_completion_guard
BEFORE UPDATE OF status
ON trips
FOR EACH ROW
EXECUTE FUNCTION validate_trip_cargo_before_completion();


-- =========================================================
-- 5. PROHIBITION OF FURTHER LOADING AFTER DISPATCH
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_loading_after_trip_departure()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_trip_status TEXT;
  v_shipment_status TEXT;
BEGIN
  SELECT t.status, s.status
  INTO v_trip_status, v_shipment_status
  FROM shipment_items si
  JOIN shipments s ON s.id = si.shipment_id
  LEFT JOIN trips t ON t.id = s.trip_id
  WHERE si.id = NEW.shipment_item_id;

  IF v_trip_status IN ('in_transit', 'delivered', 'cancelled') THEN
    RAISE EXCEPTION
      'Не можна завантажувати товар після відправлення транспортного засобу';
  END IF;

  IF v_shipment_status IN (
    'delivered',
    'returned',
    'lost',
    'settled',
    'cancelled',
    'partially_fulfilled'
  ) THEN
    RAISE EXCEPTION
      'Відправлення вже завершене';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_loading_trip_departure_guard
BEFORE INSERT
ON shipment_loading_movements
FOR EACH ROW
EXECUTE FUNCTION prevent_loading_after_trip_departure();


-- =========================================================
-- 6. VERIFICATION OF QUANTITY PRIOR TO TRANSFER OF RESPONSIBILITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_responsibility_transfer_quantity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_balance RECORD;
  v_already_transferred BIGINT;
BEGIN
  SELECT *
  INTO v_balance
  FROM get_shipment_item_cargo_balance(
    NEW.shipment_item_id
  );

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позицію відправлення не знайдено';
  END IF;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_already_transferred
  FROM shipment_cargo_movements
  WHERE shipment_item_id = NEW.shipment_item_id
    AND movement_type = 'responsibility_transfer';

  IF NEW.quantity >
     v_balance.unresolved_quantity - v_already_transferred THEN
    RAISE EXCEPTION
      'Передача відповідальності перевищує доступний залишок вантажу';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_responsibility_transfer_quantity_guard
BEFORE INSERT
ON trip_responsibility_transfers
FOR EACH ROW
EXECUTE FUNCTION validate_responsibility_transfer_quantity();


-- =========================================================
-- 7. SUBMISSION FOR ANALYSIS OF SHIPMENTS
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