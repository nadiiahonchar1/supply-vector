import { sql } from "@/db";
import { InventoryItem, InventoryFilters } from "../types";

export async function getInventoryQuery(
  filters?: InventoryFilters,
): Promise<InventoryItem[]> {
  const cityFilter = filters?.city ? sql`AND s.city = ${filters.city}` : sql``;

  const lowStockFilter = filters?.lowStock
    ? sql`AND i.quantity < i.min_stock`
    : sql``;

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

    JOIN stores s
      ON s.id = i.store_id

    JOIN products p
      ON p.id = i.product_id

    WHERE 1=1
    ${cityFilter}
    ${lowStockFilter}

    ORDER BY s.name, p.name;
  `;

  return result as InventoryItem[];
}
