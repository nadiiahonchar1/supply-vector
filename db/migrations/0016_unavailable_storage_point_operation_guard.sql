-- =========================================================
-- 1. ASSERT A STORAGE POINT FOR A PHYSICAL OPERATION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_storage_point_physical_operation(
  p_storage_point_id UUID,
  p_operation_type TEXT,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_storage_point_id IS NULL
     OR p_operation_type IS NULL
     OR btrim(p_operation_type) = ''
     OR p_operation_key IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_STORAGE_POINT_OPERATION';
  END IF;

  PERFORM assert_storage_point_operation_confirmed(
    p_storage_point_id,
    p_operation_type,
    p_operation_key
  );
END;
$$;


-- =========================================================
-- 2. ASSERT A SHIPMENT SOURCE OR DESTINATION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_storage_point_operation(
  p_shipment_id UUID,
  p_point_role TEXT,
  p_operation_type TEXT,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_storage_point_id UUID;
BEGIN
  IF p_shipment_id IS NULL
     OR p_point_role NOT IN ('source', 'destination') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'INVALID_SHIPMENT_STORAGE_POINT';
  END IF;

  SELECT
    CASE p_point_role
      WHEN 'source' THEN s.source_storage_point_id
      WHEN 'destination' THEN s.destination_storage_point_id
    END
  INTO v_storage_point_id
  FROM shipments s
  WHERE s.id = p_shipment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'SHIPMENT_NOT_FOUND';
  END IF;

  PERFORM assert_storage_point_physical_operation(
    v_storage_point_id,
    p_operation_type,
    p_operation_key
  );
END;
$$;


-- =========================================================
-- 3. ASSERT THE RETURN DESTINATION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_shipment_return_storage_point(
  p_storage_point_id UUID,
  p_operation_key UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_storage_point_physical_operation(
    p_storage_point_id,
    'shipment_return',
    p_operation_key
  );
END;
$$;