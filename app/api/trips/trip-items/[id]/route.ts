import { NextResponse } from "next/server";

import { updateTripItemSchema } from "@/features/trips";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { TripItemsService } from "@/lib/trips";

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
