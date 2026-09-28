import { NextResponse, NextRequest } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";

import { createTripStopSchema } from "@/features/trip-stops/validation/trip-stop.schema";
import { TripStopsService } from "@/lib/trip-stops/trip-stops.service";

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

    return NextResponse.json(tripStop, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}