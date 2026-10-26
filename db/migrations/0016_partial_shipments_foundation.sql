
-- =============================================
-- 0016: PARTIAL SHIPMENTS FOUNDATION
-- =============================================
-- Preserve existing data.
-- Legacy trip items may remain without shipment_id
-- until they can be safely linked to a real shipment.

BEGIN;

ALTER TABLE shipments
  ADD COLUMN IF NOT EXISTS transfer_request_id UUID
    REFERENCES transfer_requests(id);


UPDATE shipments s
SET transfer_request_id = tr.id
FROM transfer_requests tr
WHERE tr.shipment_id = s.id
  AND s.transfer_request_id IS NULL;

CREATE INDEX IF NOT EXISTS
  idx_shipments_transfer_request_id
ON shipments(transfer_request_id);


ALTER TABLE trip_items
  ADD COLUMN IF NOT EXISTS shipment_id UUID
    REFERENCES shipments(id);

CREATE INDEX IF NOT EXISTS
  idx_trip_items_shipment_id
ON trip_items(shipment_id);


ALTER TABLE inventory_reservations
  ADD COLUMN IF NOT EXISTS shipment_id UUID
    REFERENCES shipments(id);

CREATE INDEX IF NOT EXISTS
  idx_inventory_reservations_shipment_id
ON inventory_reservations(shipment_id);

CREATE INDEX IF NOT EXISTS
  idx_inventory_reservations_active_shipment
ON inventory_reservations(shipment_id)
WHERE released_at IS NULL
  AND shipment_id IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM shipment_items
    GROUP BY shipment_id, product_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Migration 0016 aborted: duplicate products exist in shipment_items';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'shipment_items'::regclass
      AND conname = 'uq_shipment_items_shipment_product'
  ) THEN
    ALTER TABLE shipment_items
      ADD CONSTRAINT uq_shipment_items_shipment_product
      UNIQUE (shipment_id, product_id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM shipments
    WHERE transfer_request_id IS NULL
  ) THEN
    RAISE NOTICE
      'Some shipments have no linked request; inspect before enabling the new API';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM shipments
    WHERE transfer_request_id IS NOT NULL
    GROUP BY transfer_request_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Migration 0016 aborted: multiple shipments map to one request already; inspect legacy links';
  END IF;
END;
$$;

COMMIT;
