import { sql } from "@/db";
import { ShipmentDetails } from "../types";

export async function getShipmentsQuery(): Promise<ShipmentDetails[]> {
  const rows = await sql`
    SELECT
      sh.id as shipment_id,
      sh.status,
      sh.created_at,
      sh.completed_at,

      ss.id as source_store_id,
      ss.name as source_store_name,
      ss.city as source_city,

      ds.id as destination_store_id,
      ds.name as destination_store_name,
      ds.city as destination_city,

      si.quantity,
      p.id as product_id,
      p.name as product_name,
      p.sku

    FROM shipments sh

    JOIN stores ss
      ON ss.id = sh.source_store_id

    JOIN stores ds
      ON ds.id = sh.destination_store_id

    JOIN shipment_items si
      ON si.shipment_id = sh.id

    JOIN products p
      ON p.id = si.product_id

    ORDER BY sh.created_at DESC;
  `;

  // 🔥 GROUPING (JS SIDE)
  const shipmentsMap = new Map<string, ShipmentDetails>();

  for (const row of rows) {
    if (!shipmentsMap.has(row.shipment_id)) {
      shipmentsMap.set(row.shipment_id, {
        shipment_id: row.shipment_id,
        status: row.status,
        created_at: row.created_at,
        completed_at: row.completed_at,

        source_store: {
          id: row.source_store_id,
          name: row.source_store_name,
          city: row.source_city,
        },

        destination_store: {
          id: row.destination_store_id,
          name: row.destination_store_name,
          city: row.destination_city,
        },

        items: [],
      });
    }

    const shipment = shipmentsMap.get(row.shipment_id)!;

    shipment.items.push({
      product_id: row.product_id,
      name: row.product_name,
      sku: row.sku,
      quantity: row.quantity,
    });
  }

  return Array.from(shipmentsMap.values());
}
