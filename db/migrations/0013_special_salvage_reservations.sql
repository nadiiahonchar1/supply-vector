-- =========================================================
-- 1. VALIDATE RESERVATION SOURCE CONSISTENCY
-- =========================================================

CREATE OR REPLACE FUNCTION validate_inventory_reservation_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_source RECORD;
  v_inventory RECORD;
  v_closure RECORD;
BEGIN
  IF NEW.transfer_request_source_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_SOURCE_REQUIRED';
  END IF;

  SELECT
    trs.id,
    trs.source_storage_point_id,
    trs.allocated_quantity,
    trs.closure_block_id,
    trs.closure_inspection_id,
    tri.product_id,
    tri.requested_quantity,
    tri.cancelled_quantity,
    tr.id AS request_id,
    tr.request_type,
    tr.storage_point_closure_id,
    tr.destination_storage_point_id,
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

  IF v_source.request_status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_APPROVED';
  END IF;

  SELECT
    i.id,
    i.storage_point_id,
    i.product_id
  INTO v_inventory
  FROM inventory i
  WHERE i.id = NEW.inventory_id
  FOR KEY SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVENTORY_NOT_FOUND';
  END IF;

  IF v_inventory.storage_point_id <> v_source.source_storage_point_id
     OR v_inventory.product_id <> v_source.product_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESERVATION_INVENTORY_SOURCE_MISMATCH';
  END IF;

  IF v_source.request_type = 'standard' THEN
    IF v_source.storage_point_closure_id IS NOT NULL
       OR v_source.closure_block_id IS NOT NULL
       OR v_source.closure_inspection_id IS NOT NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'STANDARD_REQUEST_CANNOT_USE_CLOSURE_SOURCE';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM storage_points sp
      WHERE sp.id = v_source.source_storage_point_id
        AND sp.status <> 'closed'
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSED_STORAGE_POINT_REQUIRES_SALVAGE_REQUEST';
    END IF;

  ELSIF v_source.request_type = 'closure_salvage' THEN
    IF v_source.storage_point_closure_id IS NULL
       OR v_source.closure_block_id IS NULL
       OR v_source.closure_inspection_id IS NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_SALVAGE_SOURCE_REQUIRED';
    END IF;

    SELECT
      cb.id,
      cb.closure_id,
      cb.storage_point_id,
      cb.product_id,
      cb.inventory_id
    INTO v_closure
    FROM storage_point_closure_blocks cb
    WHERE cb.id = v_source.closure_block_id
    FOR KEY SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_BLOCK_NOT_FOUND';
    END IF;

    IF v_closure.closure_id <> v_source.storage_point_closure_id
       OR v_closure.storage_point_id <> v_source.source_storage_point_id
       OR v_closure.product_id <> v_source.product_id
       OR v_closure.inventory_id <> NEW.inventory_id THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_RESERVATION_SOURCE_MISMATCH';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM storage_point_closures c
      WHERE c.id = v_source.storage_point_closure_id
        AND c.storage_point_id = v_source.source_storage_point_id
        AND c.reopened_at IS NULL
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_CYCLE_NOT_ACTIVE';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM storage_point_closure_inspections ci
      WHERE ci.id = v_source.closure_inspection_id
        AND ci.closure_block_id = v_source.closure_block_id
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_INSPECTION_NOT_FOUND';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM storage_points sp
      WHERE sp.id = v_source.source_storage_point_id
        AND sp.status = 'closed'
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_SOURCE_NOT_CLOSED';
    END IF;

  ELSE
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_TRANSFER_REQUEST_TYPE';
  END IF;

  IF NEW.reserved_quantity <= 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_RESERVATION_QUANTITY';
  END IF;

  IF NEW.reserved_quantity > v_source.allocated_quantity THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESERVATION_EXCEEDS_SOURCE_ALLOCATION';
  END IF;

  RETURN NEW;
END;
$$;


-- =========================================================
-- 2. ATTACH SOURCE VALIDATION TO RESERVATIONS
-- =========================================================

CREATE TRIGGER inventory_reservation_source_validation
BEFORE INSERT OR UPDATE OF
  inventory_id,
  transfer_request_source_id,
  reserved_quantity
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_reservation_source();


-- =========================================================
-- 3. PREVENT RESERVATION SOURCE REASSIGNMENT
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_inventory_reservation_source_reassignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.transfer_request_source_id
     IS DISTINCT FROM NEW.transfer_request_source_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESERVATION_SOURCE_IMMUTABLE';
  END IF;

  IF OLD.inventory_id IS DISTINCT FROM NEW.inventory_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESERVATION_INVENTORY_IMMUTABLE';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_reservation_source_immutability
BEFORE UPDATE OF transfer_request_source_id, inventory_id
ON inventory_reservations
FOR EACH ROW
EXECUTE FUNCTION prevent_inventory_reservation_source_reassignment();