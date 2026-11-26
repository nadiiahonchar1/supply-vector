-- =========================================================
-- 1. TRANSFER REQUEST TYPE
-- =========================================================

ALTER TABLE transfer_requests
ADD COLUMN request_type TEXT NOT NULL DEFAULT 'standard';

ALTER TABLE transfer_requests
ADD COLUMN storage_point_closure_id UUID
REFERENCES storage_point_closures(id)
ON DELETE RESTRICT;

ALTER TABLE transfer_requests
ADD CONSTRAINT transfer_requests_type_check
CHECK (
  (
    request_type = 'standard'
    AND storage_point_closure_id IS NULL
  )
  OR
  (
    request_type = 'closure_salvage'
    AND storage_point_closure_id IS NOT NULL
  )
);


-- =========================================================
-- 2. CLOSURE INSPECTION REFERENCE
-- =========================================================

CREATE UNIQUE INDEX storage_point_closure_inspections_id_block_uidx
ON storage_point_closure_inspections(id, closure_block_id);


-- =========================================================
-- 3. LINK TRANSFER SOURCES TO CLOSURE BLOCKS
-- =========================================================

ALTER TABLE transfer_request_sources
ADD COLUMN closure_block_id UUID;

ALTER TABLE transfer_request_sources
ADD COLUMN closure_inspection_id UUID;

ALTER TABLE transfer_request_sources
ADD CONSTRAINT transfer_request_sources_closure_reference_check
CHECK (
  (
    closure_block_id IS NULL
    AND closure_inspection_id IS NULL
  )
  OR
  (
    closure_block_id IS NOT NULL
    AND closure_inspection_id IS NOT NULL
  )
);

ALTER TABLE transfer_request_sources
ADD CONSTRAINT transfer_request_sources_closure_block_fk
FOREIGN KEY (closure_block_id)
REFERENCES storage_point_closure_blocks(id)
ON DELETE RESTRICT;

ALTER TABLE transfer_request_sources
ADD CONSTRAINT transfer_request_sources_closure_inspection_fk
FOREIGN KEY (closure_inspection_id, closure_block_id)
REFERENCES storage_point_closure_inspections(id, closure_block_id)
ON DELETE RESTRICT;

CREATE INDEX transfer_request_sources_closure_block_idx
ON transfer_request_sources(closure_block_id)
WHERE closure_block_id IS NOT NULL;


-- =========================================================
-- 4. VALIDATE CLOSURE SALVAGE SOURCES
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_closure_source()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_request_item RECORD;
  v_closure_block RECORD;
  v_inspection RECORD;
  v_allocated_quantity INTEGER;
  v_released_quantity INTEGER;
BEGIN
  SELECT
    tr.id,
    tr.request_type,
    tr.storage_point_closure_id,
    tr.destination_storage_point_id,
    tr.status
  INTO v_request
  FROM transfer_requests tr
  JOIN transfer_request_items tri
    ON tri.request_id = tr.id
  WHERE tri.id = NEW.transfer_request_item_id
  FOR UPDATE OF tr;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_ITEM_NOT_FOUND';
  END IF;

  SELECT
    tri.id,
    tri.product_id,
    tri.requested_quantity,
    tri.cancelled_quantity
  INTO v_request_item
  FROM transfer_request_items tri
  WHERE tri.id = NEW.transfer_request_item_id;

  IF v_request.status <> 'draft' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TRANSFER_REQUEST_NOT_EDITABLE';
  END IF;

  IF NEW.closure_block_id IS NULL THEN
    IF v_request.request_type <> 'standard' THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'CLOSURE_SALVAGE_SOURCE_REQUIRED';
    END IF;

    RETURN NEW;
  END IF;

  IF v_request.request_type <> 'closure_salvage'
     OR v_request.storage_point_closure_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_CLOSURE_SALVAGE_REQUEST';
  END IF;

  SELECT
    cb.id,
    cb.closure_id,
    cb.storage_point_id,
    cb.product_id,
    cb.initial_quantity,
    cb.released_quantity
  INTO v_closure_block
  FROM storage_point_closure_blocks cb
  WHERE cb.id = NEW.closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'CLOSURE_BLOCK_NOT_FOUND';
  END IF;

  IF v_closure_block.closure_id <> v_request.storage_point_closure_id
     OR v_closure_block.storage_point_id <> NEW.source_storage_point_id
     OR v_closure_block.product_id <> v_request_item.product_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'CLOSURE_SOURCE_MISMATCH';
  END IF;

  IF NEW.source_storage_point_id = v_request.destination_storage_point_id THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SOURCE_EQUALS_DESTINATION';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_points sp
    WHERE sp.id = NEW.source_storage_point_id
      AND sp.status = 'closed'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'CLOSURE_SOURCE_NOT_CLOSED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage_points sp
    WHERE sp.id = v_request.destination_storage_point_id
      AND sp.status <> 'closed'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'DESTINATION_NOT_AVAILABLE';
  END IF;

  SELECT
    ci.id,
    ci.closure_block_id,
    ci.suitable_quantity
  INTO v_inspection
  FROM storage_point_closure_inspections ci
  WHERE ci.id = NEW.closure_inspection_id
    AND ci.closure_block_id = NEW.closure_block_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'CLOSURE_INSPECTION_NOT_FOUND';
  END IF;

  IF NEW.allocated_quantity <= 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_SOURCE_ALLOCATION';
  END IF;

  SELECT COALESCE(SUM(trs.allocated_quantity), 0)
  INTO v_allocated_quantity
  FROM transfer_request_sources trs
  JOIN transfer_request_items tri
    ON tri.id = trs.transfer_request_item_id
  JOIN transfer_requests tr
    ON tr.id = tri.request_id
  WHERE trs.closure_inspection_id = NEW.closure_inspection_id
    AND trs.id IS DISTINCT FROM NEW.id
    AND tr.status NOT IN ('cancelled');

  SELECT COALESCE(SUM(m.quantity), 0)
  INTO v_released_quantity
  FROM storage_point_closure_block_movements m
  WHERE m.inspection_id = NEW.closure_inspection_id
    AND m.movement_type = 'release';

  IF v_allocated_quantity + v_released_quantity + NEW.allocated_quantity
     > v_inspection.suitable_quantity THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INSUFFICIENT_INSPECTED_SALVAGE_QUANTITY';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_closure_source_validation
BEFORE INSERT OR UPDATE OF
  transfer_request_item_id,
  source_storage_point_id,
  allocated_quantity,
  closure_block_id,
  closure_inspection_id
ON transfer_request_sources
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_closure_source();


-- =========================================================
-- 5. PREVENT REQUEST TYPE CHANGES AFTER CREATION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_type_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.request_type IS DISTINCT FROM NEW.request_type
     OR OLD.storage_point_closure_id IS DISTINCT FROM NEW.storage_point_closure_id
  THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TRANSFER_REQUEST_TYPE_IMMUTABLE';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM transfer_request_sources trs
      JOIN transfer_request_items tri
        ON tri.id = trs.transfer_request_item_id
      WHERE tri.request_id = OLD.id
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TRANSFER_REQUEST_SOURCES_ALREADY_DEFINED';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_type_immutability
BEFORE UPDATE OF request_type, storage_point_closure_id
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_type_change();