"use server";

import { sql } from "@/db";
import { ShipmentStatus } from "../types";
import { canTransition } from "../utils/can-transition";

type Params = {
  shipmentId: string;
  status: ShipmentStatus;
  currentStatus: ShipmentStatus;
};

export async function updateShipmentStatusAction({
  shipmentId,
  status,
  currentStatus,
}: Params) {
  if (!canTransition(currentStatus, status)) {
    throw new Error("Invalid status transition");
  }

  const shipmentRows = await sql`
    SELECT
      source_store_id,
      destination_store_id
    FROM shipments
    WHERE id = ${shipmentId}
  `;

  const shipment = shipmentRows[0];

   if (!shipment) {
     throw new Error("Shipment not found");
   }

   const items = await sql`
    SELECT
      product_id,
      quantity
    FROM shipment_items
    WHERE shipment_id = ${shipmentId}
  `;

   if (currentStatus === "pending" && status === "in_transit") {
     for (const item of items) {
       const inventoryRows = await sql`
      SELECT quantity
      FROM inventory
      WHERE store_id = ${shipment.source_store_id}
        AND product_id = ${item.product_id}
    `;

       const inventory = inventoryRows[0];

       if (!inventory) {
         throw new Error(`Product ${item.product_id} not found in inventory`);
       }

       if (inventory.quantity < item.quantity) {
         throw new Error(`Not enough stock for product ${item.product_id}`);
       }

       await sql`
      UPDATE inventory
      SET quantity = quantity - ${item.quantity},
          updated_at = NOW()
      WHERE store_id = ${shipment.source_store_id}
        AND product_id = ${item.product_id}
    `;
     }
   }

  const completedAt = status === "completed" ? new Date().toISOString() : null;

  await sql`
    UPDATE shipments
    SET status = ${status},
        completed_at = ${completedAt}
    WHERE id = ${shipmentId}
  `;
}
