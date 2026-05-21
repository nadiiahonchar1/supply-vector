import { sql } from "@/db";
import { InventoryItem, LowStockItem } from "../types";

export async function getLowStockQuery(): Promise<LowStockItem[]> {
  const result = await sql`
    SELECT
      s.id as store_id,
      s.name as store_name,
      s.city,

      p.id as product_id,
      p.name as product_name,
      p.sku,

      i.quantity,
      i.min_stock

    FROM inventory i
    JOIN stores s ON s.id = i.store_id
    JOIN products p ON p.id = i.product_id

    WHERE i.quantity < i.min_stock

    ORDER BY i.quantity ASC;
  `;

  return result as InventoryItem[];
}
