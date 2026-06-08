import { sql } from "@/db";
import { ShipmentDetails, ShipmentFilters, ShipmentRow } from "../types";
import { mapShipmentRows } from "../utils/map-shipment-rows";

export async function getShipmentsQuery(
  filters?: ShipmentFilters,
): Promise<ShipmentDetails[]> {
  const statusFilter = filters?.status
    ? sql`AND sh.status = ${filters.status}`
    : sql``;

  const sourceStoreFilter = filters?.sourceStoreId
    ? sql`AND sh.source_store_id = ${filters.sourceStoreId}`
    : sql``;

  const destinationStoreFilter = filters?.destinationStoreId
    ? sql`AND sh.destination_store_id = ${filters.destinationStoreId}`
    : sql``;

  const rows = await sql`
    SELECT
      sh.id as shipment_id,
      sh.status,
      sh.created_at,
      sh.completed_at,

      ss.id as source_store_id,
      ss.name as source_store_name,
      ss.city as source_store_city,

      ds.id as destination_store_id,
      ds.name as destination_store_name,
      ds.city as destination_store_city,

      p.id as product_id,
      p.name as product_name,
      p.sku as product_sku,

      si.quantity

    FROM shipments sh

    JOIN stores ss
      ON ss.id = sh.source_store_id

    JOIN stores ds
      ON ds.id = sh.destination_store_id

    JOIN shipment_items si
      ON si.shipment_id = sh.id

    JOIN products p
      ON p.id = si.product_id

    WHERE 1=1
      ${statusFilter}
      ${sourceStoreFilter}
      ${destinationStoreFilter}

    ORDER BY sh.created_at DESC;
  `;

  return mapShipmentRows(rows as ShipmentRow[]);
}