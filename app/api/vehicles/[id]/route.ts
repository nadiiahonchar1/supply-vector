import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { VehiclesService } from "@/lib/vehicles/vehicles.service";
import { updateVehicleSchema } from "@/features/vehicles/validation/vehicle.schema";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const vehicle = await VehiclesService.getVehicleById(id, currentUser);

    return NextResponse.json(vehicle);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;
    const body = await request.json();

    const input = validate(updateVehicleSchema, body);

    const vehicle = await VehiclesService.updateVehicle(id, input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "vehicle:update",
      entity: "vehicle",
      entityId: vehicle.id,
      meta: {
        name: vehicle.name,
        type: vehicle.type,
      },
    });

    return NextResponse.json(vehicle);
  } catch (error) {
    return handleApiError(error);
  }
}
