import { NextResponse } from "next/server";

import { updateShipmentSchema } from "@/features/shipments";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { ShipmentsService } from "@/lib/shipments";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const shipment = await ShipmentsService.getShipmentById(id, currentUser);

    return NextResponse.json(shipment);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const body: unknown = await request.json();
    const input = validate(updateShipmentSchema, body);

    const shipment = await ShipmentsService.updateShipment(
      id,
      input,
      currentUser,
    );

    const action =
      shipment.status === "completed"
        ? "shipment:complete"
        : shipment.status === "cancelled"
          ? "shipment:cancel"
          : "shipment:update";

    await AuditService.log({
      userId: currentUser.id,
      action,
      entity: "shipment",
      entityId: shipment.id,
      meta: {
        shipment_number: shipment.shipment_number,
        status: shipment.status,
      },
    });

    return NextResponse.json(shipment);
  } catch (error) {
    return handleApiError(error);
  }
}
