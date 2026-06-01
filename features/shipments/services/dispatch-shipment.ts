import { sql } from "@/db";

export async function dispatchShipment(shipmentId: string) {
  const items = await sql`
    SELECT product_id, quantity, shipment_id
    FROM shipment_items
    WHERE shipment_id = ${shipmentId}
  `;

  const shipment = await sql`
    SELECT source_store_id, destination_store_id
    FROM shipments
    WHERE id = ${shipmentId}
  `;

  const { source_store_id, destination_store_id } = shipment[0];

  for (const item of items) {
    await sql`
      UPDATE inventory
      SET quantity = quantity - ${item.quantity}
      WHERE store_id = ${source_store_id}
        AND product_id = ${item.product_id}
    `;
    
    await sql`
      INSERT INTO inventory (store_id, product_id, quantity, min_stock)
      VALUES (${destination_store_id}, ${item.product_id}, ${item.quantity}, 0)
      ON CONFLICT (store_id, product_id)
      DO UPDATE SET quantity = inventory.quantity + EXCLUDED.quantity;
    `;
  }

  await sql`
    UPDATE shipments
    SET status = 'completed',
        completed_at = NOW()
    WHERE id = ${shipmentId};
  `;
}
