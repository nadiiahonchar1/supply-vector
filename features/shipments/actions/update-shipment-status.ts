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

  const completedAt = status === "completed" ? new Date().toISOString() : null;

  await sql`
    UPDATE shipments
    SET status = ${status},
        completed_at = ${completedAt}
    WHERE id = ${shipmentId}
  `;
}
