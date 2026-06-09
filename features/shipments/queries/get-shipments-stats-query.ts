import { sql } from "@/db";

export type ShipmentsStats = {
  pending: number;
  in_transit: number;
  completed: number;
  cancelled: number;
  total: number;
};

export async function getShipmentsStatsQuery(): Promise<ShipmentsStats> {
  const rows = await sql`
    SELECT
      status,
      COUNT(*)::int as count
    FROM shipments
    GROUP BY status;
  `;

  const stats: ShipmentsStats = {
    pending: 0,
    in_transit: 0,
    completed: 0,
    cancelled: 0,
    total: 0,
  };

  for (const row of rows) {
    stats[row.status as keyof Omit<ShipmentsStats, "total">] = row.count;
    stats.total += row.count;
  }

  return stats;
}
