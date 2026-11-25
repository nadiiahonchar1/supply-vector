-- =========================================================
-- 1. IDEMPOTENCY KEY FOR OPERATIONS
-- =========================================================

ALTER TABLE salvage_cargo_dispositions
  ADD COLUMN IF NOT EXISTS operation_key UUID;

CREATE UNIQUE INDEX IF NOT EXISTS
  salvage_cargo_dispositions_operation_key_uidx
ON salvage_cargo_dispositions(operation_key)
WHERE operation_key IS NOT NULL;


-- =========================================================
-- 2. UNIFIED PROCEDURE FOR REGISTERING A CARGO SHARE
-- =========================================================

CREATE OR REPLACE FUNCTION register_salvage_disposition(
  p_salvage_request_item_id UUID,
  p_shipment_item_id UUID,
  p_disposition_type TEXT,
  p_quantity INTEGER,
  p_reason TEXT,
  p_responsible_user_id UUID,
  p_actor_user_id UUID,
  p_operation_key UUID,
  p_return_storage_point_id UUID DEFAULT NULL,
  p_act_number TEXT DEFAULT NULL,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request_id UUID;
  v_shipment_id UUID;
  v_shipment_request_id UUID;
  v_loaded INTEGER;
  v_received INTEGER;
  v_disposed INTEGER;
  v_disposition_id UUID;
  v_inventory_id UUID;
BEGIN
  -- -------------------------------------------------------
  -- 2.1. Basic validation
  -- -------------------------------------------------------

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Кількість має бути більшою за нуль';
  END IF;

  IF p_disposition_type NOT IN (
    'returned',
    'lost',
    'written_off'
  ) THEN
    RAISE EXCEPTION 'Невідомий тип операції';
  END IF;

  IF NULLIF(TRIM(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'Необхідно вказати причину';
  END IF;

  IF p_disposition_type = 'returned'
     AND p_return_storage_point_id IS NULL THEN
    RAISE EXCEPTION
      'Для повернення необхідно вказати точку призначення';
  END IF;

  IF p_disposition_type = 'written_off'
     AND NULLIF(TRIM(p_act_number), '') IS NULL THEN
    RAISE EXCEPTION
      'Для списання необхідно вказати номер акта';
  END IF;

  IF p_operation_key IS NULL THEN
    RAISE EXCEPTION
      'Необхідний ключ ідемпотентності';
  END IF;

  -- -------------------------------------------------------
  -- 2.2. Blocking of an application position
  -- -------------------------------------------------------

  SELECT salvage_request_id
  INTO v_request_id
  FROM salvage_request_items
  WHERE id = p_salvage_request_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Позицію salvage-заявки не знайдено';
  END IF;

  -- -------------------------------------------------------
  -- 2.3. Shipment check
  -- -------------------------------------------------------

  SELECT
    si.shipment_id,
    s.salvage_request_id
  INTO
    v_shipment_id,
    v_shipment_request_id
  FROM shipment_items si
  JOIN shipments s
    ON s.id = si.shipment_id
  WHERE si.id = p_shipment_item_id
    AND si.salvage_request_item_id = p_salvage_request_item_id
  FOR UPDATE OF si;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Позиція відправлення не відповідає salvage-заявці';
  END IF;

  IF v_shipment_request_id <> v_request_id THEN
    RAISE EXCEPTION
      'Відправлення належить іншій заявці';
  END IF;

  -- -------------------------------------------------------
  -- 2.4. Verification of the actual loaded quantity
  -- -------------------------------------------------------

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_loaded
  FROM shipment_cargo_movements
  WHERE shipment_id = v_shipment_id
    AND shipment_item_id = p_shipment_item_id
    AND movement_type = 'loaded';

  -- -------------------------------------------------------
  -- 2.5. Verification of the quantity already accepted
  -- -------------------------------------------------------

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_received
  FROM salvage_item_execution_events
  WHERE shipment_item_id = p_shipment_item_id
    AND event_type = 'received';

  -- -------------------------------------------------------
  -- 2.6. Перевірка попередніх рішень
  -- -------------------------------------------------------

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_disposed
  FROM salvage_cargo_dispositions
  WHERE shipment_item_id = p_shipment_item_id;

  IF v_received + v_disposed + p_quantity > v_loaded THEN
    RAISE EXCEPTION
      'Кількість перевищує невирішений завантажений вантаж';
  END IF;

  -- -------------------------------------------------------
  -- 2.7. Review of previous decisions
  -- -------------------------------------------------------

  INSERT INTO salvage_cargo_dispositions (
    salvage_request_item_id,
    shipment_item_id,
    disposition_type,
    quantity,
    destination_storage_point_id,
    reason,
    act_number,
    responsible_user_id,
    created_by,
    comment,
    operation_key
  )
  VALUES (
    p_salvage_request_item_id,
    p_shipment_item_id,
    p_disposition_type,
    p_quantity,
    p_return_storage_point_id,
    p_reason,
    p_act_number,
    p_responsible_user_id,
    p_actor_user_id,
    p_comment,
    p_operation_key
  )
  RETURNING id INTO v_disposition_id;

  -- -------------------------------------------------------
  -- 2.8. Creating a physical event
  -- -------------------------------------------------------

  INSERT INTO salvage_item_execution_events (
    salvage_request_item_id,
    shipment_item_id,
    event_type,
    quantity,
    created_by,
    comment,
    disposition_id
  )
  VALUES (
    p_salvage_request_item_id,
    p_shipment_item_id,
    p_disposition_type,
    p_quantity,
    p_actor_user_id,
    p_comment,
    v_disposition_id
  );

  -- -------------------------------------------------------
  -- 2.9. Returning an item to inventory
  -- -------------------------------------------------------

  IF p_disposition_type = 'returned' THEN

    SELECT i.id
    INTO v_inventory_id
    FROM inventory i
    JOIN shipment_items si
      ON si.product_id = i.product_id
    WHERE si.id = p_shipment_item_id
      AND i.storage_point_id = p_return_storage_point_id
    FOR UPDATE OF i;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'Інвентар товару у точці повернення не знайдено';
    END IF;

    PERFORM register_salvage_physical_return(
      v_disposition_id,
      v_inventory_id,
      p_actor_user_id,
      p_comment
    );

  END IF;

  RETURN v_disposition_id;
END;
$$;


-- =========================================================
-- 3. PROTECTION AGAINST RE-CREATION OF AN EVENT
-- =========================================================

CREATE UNIQUE INDEX IF NOT EXISTS
  salvage_execution_disposition_uidx
ON salvage_item_execution_events(disposition_id)
WHERE disposition_id IS NOT NULL;


-- =========================================================
-- 4. REVIEW OF OPERATIONAL INTEGRITY
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_operation_integrity AS
SELECT
  d.id AS disposition_id,
  d.operation_key,
  d.disposition_type,
  d.quantity,

  e.id AS execution_event_id,

  r.id AS physical_return_id,

  CASE
    WHEN e.id IS NULL THEN 'missing_event'
    WHEN d.disposition_type = 'returned'
      AND r.id IS NULL THEN 'missing_physical_return'
    ELSE 'consistent'
  END AS integrity_status

FROM salvage_cargo_dispositions d

LEFT JOIN salvage_item_execution_events e
  ON e.disposition_id = d.id

LEFT JOIN salvage_physical_returns r
  ON r.disposition_id = d.id;