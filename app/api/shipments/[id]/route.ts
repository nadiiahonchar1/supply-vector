import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { ShipmentsService } from "@/lib/shipments/shipments.service";
import { updateShipmentSchema } from "@/features/shipments/validation/shipment.schema";

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

    const body = await request.json();

    const input = validate(updateShipmentSchema, body);

    const shipment = await ShipmentsService.updateShipment(
      id,
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "shipment:update",
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
