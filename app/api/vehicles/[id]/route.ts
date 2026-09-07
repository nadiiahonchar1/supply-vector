import { NextResponse } from "next/server";

import { VehiclesService } from "@/lib/vehicles";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { updateVehicleSchema } from "@/features/vehicles/validation/vehicle.schema";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const { id } = await params;

    const vehicle = await VehiclesService.getVehicle(id);

    return NextResponse.json(vehicle);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const { id } = await params;
    const body = await request.json();

    const data = updateVehicleSchema.parse(body);

    const vehicle = await VehiclesService.updateVehicle(id, data);

    return NextResponse.json(vehicle);
  } catch (error) {
    return handleApiError(error);
  }
}
