-- =========================================================
-- 1. LOG OF PARTIAL CANCELLATION OF APPLICATION ITEMS
-- =========================================================

CREATE TABLE transfer_request_item_cancellations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_item_id UUID NOT NULL
    REFERENCES transfer_request_items(id),

  quantity INTEGER NOT NULL CHECK (quantity > 0),

  reason TEXT NOT NULL
    CHECK (LENGTH(TRIM(reason)) BETWEEN 1 AND 2000),

  released_reservations JSONB NOT NULL DEFAULT '[]'::JSONB
    CHECK (jsonb_typeof(released_reservations) = 'array'),

  operation_key UUID NOT NULL UNIQUE,

  created_by UUID NOT NULL REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX transfer_request_item_cancellations_item_idx
  ON transfer_request_item_cancellations(transfer_request_item_id);


-- =========================================================
-- 2. CANCELLATION LOG — APPEND-ONLY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_cancellation_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Журнал скасувань є незмінним';
END;
$$;

CREATE TRIGGER transfer_request_cancellations_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_item_cancellations
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_cancellation_mutation();


-- =========================================================
-- 3. PARTIAL QUANTITY CANCELLATION FUNCTION
-- =========================================================

CREATE OR REPLACE FUNCTION cancel_transfer_request_quantity(
  p_transfer_request_item_id UUID,
  p_quantity INTEGER,
  p_reservation_releases JSONB,
  p_user_id UUID,
  p_operation_key UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_item RECORD;
  v_request RECORD;

  v_existing_id UUID;
  v_cancellation_id UUID;

  v_received BIGINT := 0;
  v_loaded BIGINT := 0;
  v_resolved BIGINT := 0;
  v_unresolved_loaded BIGINT := 0;

  v_active_reserved BIGINT := 0;
  v_selected_release BIGINT := 0;
  v_unreserved_available BIGINT := 0;

  v_release RECORD;
  v_reservation RECORD;

  v_remaining INTEGER;
  v_release_operation_key UUID;
BEGIN
 
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION
      'Кількість скасування має бути більшою за нуль';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION 'operation_key є обов’язковим';
  END IF;

  IF p_reservation_releases IS NULL
     OR jsonb_typeof(p_reservation_releases) <> 'array' THEN
    RAISE EXCEPTION
      'Перелік резервів для звільнення повинен бути JSON-масивом';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину скасування';
  END IF;

  SELECT id
  INTO v_existing_id
  FROM transfer_request_item_cancellations
  WHERE operation_key = p_operation_key;

  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  SELECT *
  INTO v_item
  FROM transfer_request_items
  WHERE id = p_transfer_request_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію заявки не знайдено';
  END IF;

  SELECT *
  INTO v_request
  FROM transfer_requests
  WHERE id = v_item.transfer_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Скасування кількості доступне лише для погодженої або виконуваної заявки';
  END IF;

  SELECT COALESCE(SUM(srm.quantity), 0)
  INTO v_received
  FROM shipment_receipt_movements srm
  JOIN shipment_items si
    ON si.id = srm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(slm.quantity), 0)
  INTO v_loaded
  FROM shipment_loading_movements slm
  JOIN shipment_items si
    ON si.id = slm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  SELECT COALESCE(SUM(scm.quantity), 0)
  INTO v_resolved
  FROM shipment_cargo_movements scm
  JOIN shipment_items si
    ON si.id = scm.shipment_item_id
  JOIN transfer_request_sources trs
    ON trs.id = si.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  v_unresolved_loaded := v_loaded - v_received - v_resolved;

  IF v_unresolved_loaded < 0 THEN
    RAISE EXCEPTION
      'Некоректний баланс завантаженого товару';
  END IF;

  SELECT COALESCE(
    SUM(
      ir.reserved_quantity
      - ir.consumed_quantity
      - ir.released_quantity
    ),
    0
  )
  INTO v_active_reserved
  FROM inventory_reservations ir
  JOIN transfer_request_sources trs
    ON trs.id = ir.transfer_request_source_id
  WHERE trs.transfer_request_item_id = p_transfer_request_item_id;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_reservation_releases)
      AS r(reservation_id UUID, quantity INTEGER)
    WHERE r.reservation_id IS NULL
       OR r.quantity IS NULL
       OR r.quantity <= 0
  ) THEN
    RAISE EXCEPTION
      'Кожен резерв повинен містити ID та додатну кількість';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM jsonb_to_recordset(p_reservation_releases)
      AS r(reservation_id UUID, quantity INTEGER)
  ) <>
  (
    SELECT COUNT(DISTINCT r.reservation_id)
    FROM jsonb_to_recordset(p_reservation_releases)
      AS r(reservation_id UUID, quantity INTEGER)
  ) THEN
    RAISE EXCEPTION
      'Один резерв не можна вказувати декілька разів';
  END IF;

  SELECT COALESCE(SUM(r.quantity), 0)
  INTO v_selected_release
  FROM jsonb_to_recordset(p_reservation_releases)
    AS r(reservation_id UUID, quantity INTEGER);

  IF v_selected_release > p_quantity THEN
    RAISE EXCEPTION
      'Звільнення резервів перевищує кількість скасування';
  END IF;
  
  v_unreserved_available :=
    v_item.requested_quantity
    - v_item.cancelled_quantity
    - v_received
    - v_unresolved_loaded
    - v_active_reserved;

  IF v_unreserved_available < 0 THEN
    RAISE EXCEPTION
      'Виявлено некоректний баланс потреби та резервів';
  END IF;

  IF p_quantity >
     v_unreserved_available + v_selected_release THEN
    RAISE EXCEPTION
      'Недостатньо незарезервованої кількості та вибраних резервів для скасування';
  END IF;

  IF v_item.cancelled_quantity + p_quantity >
     v_item.requested_quantity - v_received - v_unresolved_loaded THEN
    RAISE EXCEPTION
      'Скасування перевищує залишок потреби';
  END IF;

  FOR v_release IN
    SELECT
      r.reservation_id,
      r.quantity
    FROM jsonb_to_recordset(p_reservation_releases)
      AS r(reservation_id UUID, quantity INTEGER)
  LOOP
    SELECT ir.*
    INTO v_reservation
    FROM inventory_reservations ir
    JOIN transfer_request_sources trs
      ON trs.id = ir.transfer_request_source_id
    WHERE ir.id = v_release.reservation_id
      AND trs.transfer_request_item_id =
          p_transfer_request_item_id
    FOR UPDATE OF ir;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'Вибраний резерв не належить цій позиції заявки';
    END IF;

    v_remaining :=
      v_reservation.reserved_quantity
      - v_reservation.consumed_quantity
      - v_reservation.released_quantity;

    IF v_release.quantity > v_remaining THEN
      RAISE EXCEPTION
        'Кількість звільнення перевищує залишок вибраного резерву';
    END IF;

    v_release_operation_key := gen_random_uuid();

    PERFORM release_inventory_reservation(
      v_release.reservation_id,
      v_release.quantity,
      'Скасування частини потреби заявки: ' || TRIM(p_reason),
      'transfer_request_item_cancellation',
      p_operation_key,
      p_user_id,
      v_release_operation_key
    );
  END LOOP;

  INSERT INTO transfer_request_item_cancellations (
    transfer_request_item_id,
    quantity,
    reason,
    released_reservations,
    operation_key,
    created_by
  )
  VALUES (
    p_transfer_request_item_id,
    p_quantity,
    TRIM(p_reason),
    p_reservation_releases,
    p_operation_key,
    p_user_id
  )
  RETURNING id INTO v_cancellation_id;

  UPDATE transfer_request_items
  SET cancelled_quantity = cancelled_quantity + p_quantity
  WHERE id = p_transfer_request_item_id;

  RETURN v_cancellation_id;
END;
$$;


-- =========================================================
-- 4. PROHIBITION ON EXCEEDING THE CANCELED QUANTITY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_item_quantities()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.cancelled_quantity > NEW.requested_quantity THEN
    RAISE EXCEPTION
      'Скасована кількість не може перевищувати запитану';
  END IF;

  IF NEW.requested_quantity < OLD.requested_quantity
     AND NEW.cancelled_quantity > 0 THEN
    RAISE EXCEPTION
      'Не можна зменшити потребу нижче вже скасованої кількості';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_item_quantity_guard
BEFORE UPDATE OF requested_quantity, cancelled_quantity
ON transfer_request_items
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_item_quantities();