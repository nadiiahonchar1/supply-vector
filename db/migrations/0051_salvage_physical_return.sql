-- =========================================================
-- 1. PHYSICAL RECOVERY JOURNAL
-- =========================================================

CREATE TABLE salvage_physical_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  disposition_id UUID NOT NULL UNIQUE
    REFERENCES salvage_cargo_dispositions(id),

  inventory_id UUID NOT NULL
    REFERENCES inventory(id),

  quantity INTEGER NOT NULL,

  inventory_movement_id UUID
    REFERENCES inventory_movements(id),

  returned_by UUID NOT NULL
    REFERENCES users(id),

  comment TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_physical_return_quantity_check
    CHECK (quantity > 0)
);

CREATE INDEX salvage_physical_returns_inventory_idx
  ON salvage_physical_returns(inventory_id);


-- =========================================================
-- 2. RETURNS LOG PROTECTION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_physical_return_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Фізичне повернення товару не можна змінювати або видаляти';
END;
$$;

CREATE TRIGGER salvage_physical_returns_immutable
BEFORE UPDATE OR DELETE
ON salvage_physical_returns
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_physical_return_mutation();


-- =========================================================
-- 3. ПЕРЕВІРКА ТОЧКИ ПОВЕРНЕННЯ
-- =========================================================

CREATE OR REPLACE FUNCTION validate_salvage_physical_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_disposition RECORD;
  v_inventory RECORD;
BEGIN
  SELECT
    d.id,
    d.disposition_type,
    d.quantity,
    d.destination_storage_point_id,
    d.shipment_item_id,
    d.salvage_request_item_id
  INTO v_disposition
  FROM salvage_cargo_dispositions d
  WHERE d.id = NEW.disposition_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Рішення щодо повернення не знайдено';
  END IF;

  IF v_disposition.disposition_type <> 'returned' THEN
    RAISE EXCEPTION
      'Фізичне повернення дозволене лише для рішення returned';
  END IF;

  IF NEW.quantity <> v_disposition.quantity THEN
    RAISE EXCEPTION
      'Кількість повернення не відповідає погодженому рішенню';
  END IF;

  SELECT
    i.id,
    i.storage_point_id,
    i.product_id
  INTO v_inventory
  FROM inventory i
  WHERE i.id = NEW.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис інвентарю не знайдено';
  END IF;

  IF v_inventory.storage_point_id <>
     v_disposition.destination_storage_point_id THEN
    RAISE EXCEPTION
      'Товар повертається не в ту точку, яку визначено рішенням';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM shipment_items si
    WHERE si.id = v_disposition.shipment_item_id
      AND si.product_id = v_inventory.product_id
  ) THEN
    RAISE EXCEPTION
      'Товар інвентарю не відповідає товару відправлення';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_physical_return_validation
BEFORE INSERT
ON salvage_physical_returns
FOR EACH ROW
EXECUTE FUNCTION validate_salvage_physical_return();


-- =========================================================
-- 4. CHECKING THE RETURN POINT
-- =========================================================

CREATE OR REPLACE FUNCTION register_salvage_physical_return(
  p_disposition_id UUID,
  p_inventory_id UUID,
  p_user_id UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_disposition RECORD;
  v_inventory RECORD;
  v_movement_id UUID;
  v_return_id UUID;
BEGIN
  SELECT *
  INTO v_disposition
  FROM salvage_cargo_dispositions
  WHERE id = p_disposition_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Рішення щодо повернення не знайдено';
  END IF;

  IF v_disposition.disposition_type <> 'returned' THEN
    RAISE EXCEPTION
      'Це рішення не передбачає фізичного повернення';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM salvage_physical_returns
    WHERE disposition_id = p_disposition_id
  ) THEN
    RAISE EXCEPTION
      'Фізичне повернення за цим рішенням уже зареєстровано';
  END IF;

  SELECT *
  INTO v_inventory
  FROM inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запис інвентарю не знайдено';
  END IF;

  IF v_inventory.storage_point_id <>
     v_disposition.destination_storage_point_id THEN
    RAISE EXCEPTION
      'Неправильна точка повернення';
  END IF;

  PERFORM adjust_inventory(
    p_inventory_id,
    v_disposition.quantity,
    'salvage_return',
    p_user_id,
    p_comment
  );

  SELECT id
  INTO v_movement_id
  FROM inventory_movements
  WHERE inventory_id = p_inventory_id
  ORDER BY created_at DESC
  LIMIT 1;

  INSERT INTO salvage_physical_returns (
    disposition_id,
    inventory_id,
    quantity,
    inventory_movement_id,
    returned_by,
    comment
  )
  VALUES (
    p_disposition_id,
    p_inventory_id,
    v_disposition.quantity,
    v_movement_id,
    p_user_id,
    p_comment
  )
  RETURNING id INTO v_return_id;

  RETURN v_return_id;
END;
$$;


-- =========================================================
-- 5. CONTROL OF PHYSICAL RETURNS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_physical_return_status AS
SELECT
  d.id AS disposition_id,
  d.salvage_request_item_id,
  d.quantity AS expected_quantity,

  r.id AS physical_return_id,
  r.inventory_id,
  r.quantity AS returned_quantity,
  r.inventory_movement_id,

  r.returned_by,
  r.created_at,

  CASE
    WHEN r.id IS NULL THEN 'pending'
    WHEN r.quantity = d.quantity THEN 'completed'
    ELSE 'inconsistent'
  END AS return_status

FROM salvage_cargo_dispositions d

LEFT JOIN salvage_physical_returns r
  ON r.disposition_id = d.id

WHERE d.disposition_type = 'returned';