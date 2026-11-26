-- =========================================================
-- 1. ENSURE THAT A SHIPMENT ITEM HAS A VALID REQUEST SOURCE
-- =========================================================

ALTER TABLE shipment_items
ADD CONSTRAINT shipment_items_request_source_required
CHECK (
  transfer_request_source_id IS NOT NULL
);


-- =========================================================
-- 2. PREVENT DUPLICATE SOURCE ITEMS WITHIN ONE SHIPMENT
-- =========================================================

CREATE UNIQUE INDEX shipment_items_shipment_source_unique
ON shipment_items (
  shipment_id,
  transfer_request_source_id
);


-- =========================================================
-- 3. ENSURE THAT SHIPMENT QUANTITY IS POSITIVE
-- =========================================================

ALTER TABLE shipment_items
ADD CONSTRAINT shipment_items_planned_quantity_positive
CHECK (
  planned_quantity > 0
);


-- =========================================================
-- 4. ENSURE THAT EVERY SHIPMENT HAS A TRANSFER REQUEST
-- =========================================================

ALTER TABLE shipments
ALTER COLUMN transfer_request_id SET NOT NULL;


-- =========================================================
-- 5. ENSURE THAT SHIPMENT SOURCE AND DESTINATION DIFFER
-- =========================================================

ALTER TABLE shipments
ADD CONSTRAINT shipments_different_storage_points
CHECK (
  source_storage_point_id <> destination_storage_point_id
);
