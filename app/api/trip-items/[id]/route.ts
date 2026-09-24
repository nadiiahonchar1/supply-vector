import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";

import { updateTripItemSchema } from "@/features/trip-items/validation/trip-item.schema";
import { TripItemsService } from "@/lib/trip-items/trip-items.service";

type RouteContext = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const tripItem = await TripItemsService.getTripItemById(id, currentUser);

    return NextResponse.json(tripItem);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const body: unknown = await request.json();

    const data = validate(updateTripItemSchema, body);

    const tripItem = await TripItemsService.updateTripItem(
      id,
      data,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_item",
      entityId: tripItem.id,
    });

    return NextResponse.json(tripItem);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function DELETE(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    await TripItemsService.deleteTripItem(id, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "trip_item",
      entityId: id,
    });

    return NextResponse.json({
      message: "Елемент рейсу успішно видалено",
    });
  } catch (error) {
    return handleApiError(error);
  }
}
