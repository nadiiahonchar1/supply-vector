import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";

import { createTripItemSchema } from "@/features/trip-items/validation/trip-item.schema";
import { TripItemsService } from "@/lib/trip-items/trip-items.service";

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
