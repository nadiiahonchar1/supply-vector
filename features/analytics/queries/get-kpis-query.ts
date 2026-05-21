import { sql } from "@/db";
import { KPI } from "../types";

export async function getKpisQuery(): Promise<KPI> {
  const [result] = await sql`
    SELECT
      (SELECT COUNT(*) FROM stores) AS "totalStores",

      (SELECT COUNT(*) FROM products) AS "totalProducts",

      (SELECT COUNT(*)
       FROM inventory
       WHERE quantity < min_stock) AS "lowStockItems",

      (
        SELECT
          ROUND(
            COUNT(*) FILTER (WHERE quantity < min_stock)::numeric
            / NULLIF(COUNT(*), 0),
            2
          )
        FROM inventory
      ) AS "criticalRatio"
  `;

  return result as KPI;
}
