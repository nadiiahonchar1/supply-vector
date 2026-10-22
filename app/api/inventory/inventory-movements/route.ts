import { NextRequest, NextResponse } from "next/server";

import { inventoryMovementFiltersSchema } from "@/features/inventory";
import { InventoryMovementsService } from "@/lib/inventory";
import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";

export async function GET(request: NextRequest) {
  try {
    const currentUser = await requireUser();
    const searchParams = request.nextUrl.searchParams;

    const filters = validate(inventoryMovementFiltersSchema, {
      store_id: searchParams.get("store_id") ?? undefined,
      product_id: searchParams.get("product_id") ?? undefined,
      movement_type: searchParams.get("movement_type") ?? undefined,
    });

    const movements = await InventoryMovementsService.getMovements(
      currentUser,
      filters,
    );

    return NextResponse.json(movements);
  } catch (error) {
    return handleApiError(error);
  }
}
