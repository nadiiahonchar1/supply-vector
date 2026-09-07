import { NextResponse } from "next/server";

import { VehiclesService } from "@/lib/vehicles";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { createVehicleSchema } from "@/features/vehicles/validation/vehicle.schema";

export async function GET() {
  try {
    const vehicles = await VehiclesService.getVehicles();

    return NextResponse.json(vehicles);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const body = await request.json();

    const data = createVehicleSchema.parse(body);

    const vehicle = await VehiclesService.createVehicle(data);

    return NextResponse.json(vehicle, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}
