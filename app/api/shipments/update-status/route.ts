import { updateShipmentStatusQuery } from "@/features/shipments/queries/update-shipment-status-query";

export async function POST(request: Request) {
  const body = await request.json();

  await updateShipmentStatusQuery({
    shipmentId: body.shipmentId,
    status: body.status,
  });

  return Response.json({ success: true });
}
