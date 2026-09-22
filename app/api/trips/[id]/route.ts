import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";
import { updateTripSchema } from "@/features/trips/validation/trip.schema";
import { TripsService } from "@/lib/trips/trips.service";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const trip = await TripsService.getTripById(id, currentUser);

    return NextResponse.json(trip);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const body: unknown = await request.json();

    const data = validate(updateTripSchema, body);

    const trip = await TripsService.updateTrip(id, data, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip",
      entityId: trip.id,
    });

    return NextResponse.json(trip);
  } catch (error) {
    return handleApiError(error);
  }
}
