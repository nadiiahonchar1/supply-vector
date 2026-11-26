-- =========================================================
-- 1. VALIDATE SHIPMENT ITEM SOURCE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_shipment_transfer_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_shipment RECORD;
  v_source RECORD;
BEGIN
  SELECT
    s.id,
    s.transfer_request_id,
    s.source_storage_point_id,
    s.destination_storage_point_id,
    s.status
  INTO v_shipment
  FROM shipments s
  WHERE s.id = NEW.shipment_id
  FOR KEY SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_NOT_FOUND';
  END IF;

  IF NEW.transfer_request_source_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_TRANSFER_SOURCE_REQUIRED';
  END IF;

  SELECT
    trs.id,
    trs.transfer_request_item_id,
    trs.source_storage_point_id,
    trs.allocated_quantity,
    tri.product_id,
    tri.request_id,
    tr.destination_storage_point_id,
    tr.request_type,
    tr.storage_point_closure_id,
    tr.status AS request_status
  INTO v_source
  FROM transfer_request_sources trs
  JOIN transfer_request_items tri
    ON tri.id = trs.transfer_request_item_id
  JOIN transfer_requests tr
    ON tr.id = tri.request_id
  WHERE trs.id = NEW.transfer_request_source_id
  FOR KEY SHARE OF trs, tri, tr;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
  END IF;

  IF v_source.request_id <> v_shipment.transfer_request_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_REQUEST_SOURCE_MISMATCH';
  END IF;

  IF v_source.source_storage_point_id <> v_shipment.source_storage_point_id
     OR v_source.destination_storage_point_id <> v_shipment.destination_storage_point_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_STORAGE_POINT_MISMATCH';
  END IF;

  IF v_source.product_id <> NEW.product_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_PRODUCT_MISMATCH';
  END IF;

  IF v_source.request_status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_EXECUTABLE';
  END IF;

  IF NEW.planned_quantity <= 0
     OR NEW.planned_quantity > v_source.allocated_quantity THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_SHIPMENT_QUANTITY';
  END IF;

  IF v_source.request_type = 'closure_salvage' THEN
    IF v_source.storage_point_closure_id IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM storage_point_closure_blocks cb
         WHERE cb.id = v_source.id
       ) THEN
      NULL;
    END IF;

    IF v_source.storage_point_closure_id IS NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_SALVAGE_SOURCE_REQUIRED';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_transfer_source_validation
BEFORE INSERT OR UPDATE OF
  shipment_id,
  transfer_request_source_id,
  product_id,
  planned_quantity
ON shipment_items
FOR EACH ROW
EXECUTE FUNCTION validate_shipment_transfer_source();


-- =========================================================
-- 2. PREVENT SHIPMENT REQUEST AND ROUTE REASSIGNMENT
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_shipment_request_reassignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.transfer_request_id IS DISTINCT FROM NEW.transfer_request_id
     OR OLD.source_storage_point_id IS DISTINCT FROM NEW.source_storage_point_id
     OR OLD.destination_storage_point_id IS DISTINCT FROM NEW.destination_storage_point_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_REQUEST_AND_ROUTE_IMMUTABLE';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER shipment_request_reassignment_guard
BEFORE UPDATE OF
  transfer_request_id,
  source_storage_point_id,
  destination_storage_point_id
ON shipments
FOR EACH ROW
EXECUTE FUNCTION prevent_shipment_request_reassignment();


-- =========================================================
-- 3. CREATE A SHIPMENT FROM A TRANSFER REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION create_transfer_shipment(
  p_request_id UUID,
  p_created_by UUID,
  p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_item JSONB;
  v_source_id UUID;
  v_quantity INTEGER;
  v_shipment_id UUID;
  v_source RECORD;
  v_reservation RECORD;
  v_assigned_quantity INTEGER;
  v_remaining_reserved INTEGER;
  v_seen_sources UUID[] := ARRAY[]::UUID[];
  v_item_count INTEGER := 0;
BEGIN
  IF p_request_id IS NULL
     OR p_created_by IS NULL
     OR p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_SHIPMENT_INPUT';
  END IF;

  SELECT
    tr.id,
    tr.status,
    tr.request_type,
    tr.storage_point_closure_id,
    tr.destination_storage_point_id
  INTO v_request
  FROM transfer_requests tr
  WHERE tr.id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_FOUND';
  END IF;

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_EXECUTABLE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users u
    WHERE u.id = p_created_by
      AND u.is_active = TRUE
      AND u.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'ACTIVE_USER_REQUIRED';
  END IF;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(p_items)
  LOOP
    IF jsonb_typeof(v_item) <> 'object'
       OR NOT (v_item ? 'source_id')
       OR NOT (v_item ? 'quantity')
       OR jsonb_typeof(v_item->'source_id') <> 'string'
       OR jsonb_typeof(v_item->'quantity') <> 'number' THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'INVALID_SHIPMENT_ITEM';
    END IF;

    BEGIN
      v_source_id := (v_item->>'source_id')::UUID;
      v_quantity := (v_item->>'quantity')::INTEGER;
    EXCEPTION
      WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION USING
          ERRCODE = 'P0001',
          MESSAGE = 'INVALID_SHIPMENT_ITEM';
    END;

    IF v_source_id IS NULL OR v_quantity IS NULL OR v_quantity <= 0 THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'INVALID_SHIPMENT_ITEM';
    END IF;

    IF v_source_id = ANY(v_seen_sources) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'DUPLICATE_SHIPMENT_SOURCE';
    END IF;

    v_seen_sources := array_append(v_seen_sources, v_source_id);
    v_item_count := v_item_count + 1;

    SELECT
      trs.id,
      trs.transfer_request_item_id,
      trs.source_storage_point_id,
      trs.allocated_quantity,
      tri.product_id,
      tri.request_id
    INTO v_source
    FROM transfer_request_sources trs
    JOIN transfer_request_items tri
      ON tri.id = trs.transfer_request_item_id
    WHERE trs.id = v_source_id
    FOR UPDATE OF trs, tri;

    IF NOT FOUND OR v_source.request_id <> p_request_id THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TRANSFER_REQUEST_SOURCE_NOT_FOUND';
    END IF;

    SELECT
      ir.id,
      ir.reserved_quantity,
      ir.consumed_quantity,
      ir.released_quantity
    INTO v_reservation
    FROM inventory_reservations ir
    WHERE ir.transfer_request_source_id = v_source_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'INVENTORY_RESERVATION_NOT_FOUND';
    END IF;

    SELECT COALESCE(SUM(si.planned_quantity), 0)
    INTO v_assigned_quantity
    FROM shipment_items si
    JOIN shipments s
      ON s.id = si.shipment_id
    WHERE si.transfer_request_source_id = v_source_id
      AND s.status <> 'cancelled';

    v_remaining_reserved :=
      v_reservation.reserved_quantity
      - v_reservation.consumed_quantity
      - v_reservation.released_quantity
      - v_assigned_quantity;

    IF v_quantity > v_remaining_reserved THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'SHIPMENT_QUANTITY_EXCEEDS_UNASSIGNED_RESERVATION';
    END IF;
  END LOOP;

  SELECT
    trs.source_storage_point_id
  INTO v_source
  FROM transfer_request_sources trs
  JOIN transfer_request_items tri
    ON tri.id = trs.transfer_request_item_id
  WHERE trs.id = v_seen_sources[1];

  INSERT INTO shipments (
    transfer_request_id,
    source_storage_point_id,
    destination_storage_point_id,
    status,
    created_by
  )
  VALUES (
    p_request_id,
    v_source.source_storage_point_id,
    v_request.destination_storage_point_id,
    'pending',
    p_created_by
  )
  RETURNING id INTO v_shipment_id;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(p_items)
  LOOP
    v_source_id := (v_item->>'source_id')::UUID;
    v_quantity := (v_item->>'quantity')::INTEGER;

    SELECT
      tri.product_id
    INTO v_source
    FROM transfer_request_sources trs
    JOIN transfer_request_items tri
      ON tri.id = trs.transfer_request_item_id
    WHERE trs.id = v_source_id;

    INSERT INTO shipment_items (
      shipment_id,
      transfer_request_source_id,
      product_id,
      planned_quantity
    )
    VALUES (
      v_shipment_id,
      v_source_id,
      v_source.product_id,
      v_quantity
    );
  END LOOP;

  RETURN v_shipment_id;
END;
$$;