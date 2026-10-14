import { NextResponse } from "next/server";

import { createVehicleSchema } from "@/features/vehicles";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { VehiclesService } from "@/lib/vehicles";

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
