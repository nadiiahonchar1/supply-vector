import { NextResponse, NextRequest } from "next/server";

import { createTripStopSchema } from "@/features/trips/trip-stops";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { TripStopsService } from "@/lib/trips/trip-stops";

export async function GET(request: NextRequest) {
  try {
    const currentUser = await requireUser();

    const tripId = request.nextUrl.searchParams.get("trip_id");

    if (!tripId) {
      return NextResponse.json(
        {
          message: "trip_id is required",
        },
        { status: 400 },
      );
    }

    const tripStops = await TripStopsService.getTripStops(tripId, currentUser);

    return NextResponse.json(tripStops);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const currentUser = await requireUser();

    const body = await request.json();

    const input = validate(createTripStopSchema, body);

    const tripStop = await TripStopsService.createTripStop(input, currentUser);

    await AuditService.log({
          userId: currentUser.id,
          action: "trip:update",
          entity: "trip_stop",
          entityId: tripStop.id,
        });

    return NextResponse.json(tripStop, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}