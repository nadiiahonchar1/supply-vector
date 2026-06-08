"use server";

import { sql } from "@/db";
import { ShipmentStatus } from "../types";

type Params = {
  shipmentId: string;
  status: ShipmentStatus;
};

export async function updateShipmentStatusAction({
  shipmentId,
  status,
}: Params) {
  const completedAt = status === "completed" ? new Date().toISOString() : null;

  await sql`
    UPDATE shipments
    SET status = ${status},
        completed_at = ${completedAt}
    WHERE id = ${shipmentId}
  `;
}
