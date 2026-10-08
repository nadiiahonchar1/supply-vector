import { NextRequest, NextResponse } from "next/server";

import { InventoryService } from "@/lib/inventory/inventory.service";
import { AuditService } from "@/lib/audit/audit.service";
import { validate } from "@/lib/validation";
import { adjustInventorySchema } from "@/features/inventory/validation/inventory.schema";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function POST(request: NextRequest, context: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await context.params;
    const body = await request.json();

    const input = validate(adjustInventorySchema, body);

    const inventory = await InventoryService.adjustInventory(
      id,
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "inventory:adjust",
      entity: "inventory",
      entityId: inventory.id,
      meta: {
        quantity_change: input.quantity_change,
        movement_type: input.movement_type,
        quantity_after: inventory.quantity,
      },
    });

    return NextResponse.json(inventory);
  } catch (error) {
    return handleApiError(error);
  }
}
