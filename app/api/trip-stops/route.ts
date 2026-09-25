import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";

import { createTripStopSchema } from "@/features/trip-stops/validation/trip-stop.schema";
import { TripStopsService } from "@/lib/trip-stops/trip-stops.service";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const tripStops = await TripStopsService.getTripStops(currentUser);

    return NextResponse.json(tripStops);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();

    const body: unknown = await request.json();

    const data = validate(createTripStopSchema, body);

    const tripStop = await TripStopsService.createTripStop(data, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_stop",
      entityId: tripStop.id,
    });

    return NextResponse.json(tripStop, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
