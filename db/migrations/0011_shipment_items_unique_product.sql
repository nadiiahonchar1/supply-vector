-- =====================================
-- 0011: SHIPMENT ITEMS UNIQUE PRODUCT
-- =====================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM shipment_items
    GROUP BY shipment_id, product_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Migration 0011 failed: duplicate products found in shipment_items. Resolve duplicates before applying this migration.';
  END IF;
END $$;

ALTER TABLE shipment_items
ADD CONSTRAINT shipment_items_shipment_product_unique
UNIQUE (shipment_id, product_id);