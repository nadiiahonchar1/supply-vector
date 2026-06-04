import { sql } from "@/db";
import { StoreOption } from "../types";

export async function getStoresQuery(): Promise<StoreOption[]> {
  const result = await sql`
    SELECT
      id,
      name,
      city
    FROM stores
    ORDER BY name;
  `;

  return result as StoreOption[];
}
