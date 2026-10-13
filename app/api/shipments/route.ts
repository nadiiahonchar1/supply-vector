import { NextResponse } from "next/server";

import { createShipmentSchema } from "@/features/shipments";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { ShipmentsService } from "@/lib/shipments";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const shipments = await ShipmentsService.getShipments(currentUser);

    return NextResponse.json(shipments);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();

    const body = await request.json();

    const input = validate(createShipmentSchema, body);

    const shipment = await ShipmentsService.createShipment(input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "shipment:create",
      entity: "shipment",
      entityId: shipment.id,
      meta: {
        shipment_number: shipment.shipment_number,
        source_store_id: shipment.source_store_id,
        destination_store_id: shipment.destination_store_id,
      },
    });

    return NextResponse.json(shipment, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
