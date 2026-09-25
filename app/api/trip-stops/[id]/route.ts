import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";

import { updateTripStopSchema } from "@/features/trip-stops/validation/trip-stop.schema";
import { TripStopsService } from "@/lib/trip-stops/trip-stops.service";

type RouteContext = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const tripStop = await TripStopsService.getTripStopById(id, currentUser);

    return NextResponse.json(tripStop);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const body: unknown = await request.json();

    const data = validate(updateTripStopSchema, body);

    const tripStop = await TripStopsService.updateTripStop(
      id,
      data,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_stop",
      entityId: tripStop.id,
    });

    return NextResponse.json(tripStop);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function DELETE(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    await TripStopsService.deleteTripStop(id, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_stop",
      entityId: id,
    });

    return NextResponse.json({
      message: "Зупинку рейсу успішно видалено",
    });
  } catch (error) {
    return handleApiError(error);
  }
}
