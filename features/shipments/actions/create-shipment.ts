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

  const validItems = items.filter((i) => i.productId && i.quantity > 0);

  if (!validItems.length) {
    throw new Error("At least one item is required");
  }

  const shipmentStatus: ShipmentStatus = "pending";

  const productIds = validItems.map((i) => i.productId);

  const inventoryRows = await sql`
    SELECT product_id, quantity
    FROM inventory
    WHERE store_id = ${sourceStoreId}
      AND product_id = ANY(${productIds})
  `;

  for (const item of validItems) {
    const stock = inventoryRows.find((i) => i.product_id === item.productId);

    if (!stock) {
      throw new Error(
        `Product ${item.productId} not found in source inventory`,
      );
    }

    if (stock.quantity < item.quantity) {
      throw new Error(`Not enough stock for product ${item.productId}`);
    }
  }

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

  const values = validItems
    .map((_, i) => `($${i * 3 + 1}, $${i * 3 + 2}, $${i * 3 + 3})`)
    .join(", ");

  const flat = validItems.flatMap((item) => [
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

  for (const item of validItems) {
    await sql`
      UPDATE inventory
      SET quantity = quantity - ${item.quantity},
          updated_at = NOW()
      WHERE store_id = ${sourceStoreId}
        AND product_id = ${item.productId}
    `;
  }

  return { shipmentId };
}
