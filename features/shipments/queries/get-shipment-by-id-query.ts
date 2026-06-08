import { sql } from "@/db";
import { mapShipmentRows } from "../utils/map-shipment-rows";
import { ShipmentRow } from "../types";

export async function getShipmentByIdQuery(id: string) {
  const result = await sql`
    SELECT
      sh.id as shipment_id,
      sh.status,
      sh.created_at,
      sh.completed_at,

      source.id as source_store_id,
      source.name as source_store_name,
      source.city as source_store_city,

      destination.id as destination_store_id,
      destination.name as destination_store_name,
      destination.city as destination_store_city,

      p.id as product_id,
      p.name as product_name,
      p.sku as product_sku,

      si.quantity

    FROM shipments sh

    JOIN stores source
      ON source.id = sh.source_store_id

    JOIN stores destination
      ON destination.id = sh.destination_store_id

    JOIN shipment_items si
      ON si.shipment_id = sh.id

    JOIN products p
      ON p.id = si.product_id

    WHERE sh.id = ${id}
  `;

  const shipments = mapShipmentRows(result as ShipmentRow[]);

  return shipments[0] ?? null;
}
