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

   if (currentStatus === "in_transit" && status === "completed") {
     for (const item of items) {
       await sql`
        INSERT INTO inventory (
          store_id,
          product_id,
          quantity
        )
        VALUES (
          ${shipment.destination_store_id},
          ${item.product_id},
          ${item.quantity}
        )
        ON CONFLICT (store_id, product_id)
        DO UPDATE SET
          quantity = inventory.quantity + EXCLUDED.quantity,
          updated_at = NOW()
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
