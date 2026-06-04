export async function updateShipmentStatus(
  shipmentId: string,
  status: "pending" | "in_transit" | "completed" | "cancelled",
) {
  await fetch("/api/shipments/update-status", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ shipmentId, status }),
  });
}
