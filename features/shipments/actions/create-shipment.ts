"use server";

import { sql } from "@/db";
import type { ShipmentStatus } from "../types";

type CreateShipmentItem = {
  productId: string;
  quantity: number;
};

type CreateShipmentInput = {
  sourceStoreId: string;
  destinationStoreId: string;
  items: CreateShipmentItem[];
};

export async function createShipmentAction(input: CreateShipmentInput) {
  const { sourceStoreId, destinationStoreId, items } = input;

  if (!sourceStoreId || !destinationStoreId) {
    throw new Error("Stores are required");
  }

  if (sourceStoreId === destinationStoreId) {
    throw new Error("Source and destination must be different");
  }

  if (!items.length) {
    throw new Error("At least one item is required");
  }

  const shipmentStatus: ShipmentStatus = "pending";

  const result = await sql`
    INSERT INTO shipments (
      source_store_id,
      destination_store_id,
      status,
      created_at,
      completed_at
    )
    VALUES (
      ${sourceStoreId},
      ${destinationStoreId},
      ${shipmentStatus},
      NOW(),
      NULL
    )
    RETURNING id;
  `;

  const shipmentId = result[0].id;

  if (items.length) {
    const values = items
      .map((_, i) => `($${i * 3 + 1}, $${i * 3 + 2}, $${i * 3 + 3})`)
      .join(", ");

    const flat = items.flatMap((item) => [
      shipmentId,
      item.productId,
      item.quantity,
    ]);

    await sql.query(
      `
      INSERT INTO shipment_items (
        shipment_id,
        product_id,
        quantity
      )
      VALUES ${values}
    `,
      flat,
    );
  }

  return {
    shipmentId,
  };
}
