import { NextResponse } from "next/server";

import { createTripSchema } from "@/features/trips";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { TripsService } from "@/lib/trips";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const trips = await TripsService.getTrips(currentUser);

    return NextResponse.json(trips);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();

    const body: unknown = await request.json();

    const data = validate(createTripSchema, body);

    const trip = await TripsService.createTrip(data, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:create",
      entity: "trip",
      entityId: trip.id,
    });

    return NextResponse.json(trip, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
