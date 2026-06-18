import { ShipmentStatus } from "../types";

export async function updateShipmentStatus(
  shipmentId: string,
  status: ShipmentStatus,
) {
  await fetch("/api/shipments/update-status", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ shipmentId, status }),
  });
}
