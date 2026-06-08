import { ShipmentDetails, ShipmentRow } from "../types";

export function mapShipmentRows(rows: ShipmentRow[]): ShipmentDetails[] {
  const shipmentsMap = new Map<string, ShipmentDetails>();

  for (const row of rows) {
    let shipment = shipmentsMap.get(row.shipment_id);

    if (!shipment) {
      shipment = {
        shipment_id: row.shipment_id,

        status: row.status,

        created_at: row.created_at,
        completed_at: row.completed_at,

        source_store: {
          id: row.source_store_id,
          name: row.source_store_name,
          city: row.source_store_city,
        },

        destination_store: {
          id: row.destination_store_id,
          name: row.destination_store_name,
          city: row.destination_store_city,
        },

        items: [],
      };

      shipmentsMap.set(row.shipment_id, shipment);
    }

    shipment.items.push({
      product_id: row.product_id,
      name: row.product_name,
      sku: row.product_sku,
      quantity: row.quantity,
    });
  }

  return [...shipmentsMap.values()];
}
