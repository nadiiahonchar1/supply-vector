import { NextRequest, NextResponse } from "next/server";

import { InventoryService } from "@/lib/inventory";
import { AuditService } from "@/lib/audit";
import { validate } from "@/lib/validation";
import { updateInventorySchema } from "@/features/inventory/validation/inventory.schema";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: NextRequest, context: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await context.params;

    const inventory = await InventoryService.getInventoryById(id, currentUser);

    return NextResponse.json(inventory);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: NextRequest, context: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await context.params;
    const body = await request.json();

    const input = validate(updateInventorySchema, body);

    const inventory = await InventoryService.updateInventory(
      id,
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "inventory:update",
      entity: "inventory",
      entityId: inventory.id,
      meta: {
        min_stock: inventory.min_stock,
        max_stock: inventory.max_stock,
      },
    });

    return NextResponse.json(inventory);
  } catch (error) {
    return handleApiError(error);
  }
}
