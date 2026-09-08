import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { VehiclesService } from "@/lib/vehicles/vehicles.service";
import { createVehicleSchema } from "@/features/vehicles/validation/vehicle.schema";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const vehicles = await VehiclesService.getVehicles(currentUser);

    return NextResponse.json(vehicles);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();
    const body = await request.json();

    const input = validate(createVehicleSchema, body);

    const vehicle = await VehiclesService.createVehicle(input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "vehicle:create",
      entity: "vehicle",
      entityId: vehicle.id,
      meta: {
        name: vehicle.name,
        type: vehicle.type,
      },
    });

    return NextResponse.json(vehicle, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
