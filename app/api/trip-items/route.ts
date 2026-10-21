import { NextResponse } from "next/server";

import { createTripItemSchema } from "@/features/trips/trip-items";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { TripItemsService } from "@/lib/trip-items";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const tripItems = await TripItemsService.getTripItems(currentUser);

    return NextResponse.json(tripItems);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();

    const body: unknown = await request.json();

    const data = validate(createTripItemSchema, body);

    const tripItem = await TripItemsService.createTripItem(data, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_item",
      entityId: tripItem.id,
    });

    return NextResponse.json(tripItem, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
