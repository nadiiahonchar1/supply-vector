import { NextRequest, NextResponse } from "next/server";

import { InventoryService } from "@/lib/inventory/inventory.service";
import { AuditService } from "@/lib/audit/audit.service";
import { validate } from "@/lib/validation";
import { createInventorySchema } from "@/features/inventory/validation/inventory.schema";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const inventory = await InventoryService.getInventory(currentUser);

    return NextResponse.json(inventory);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const currentUser = await requireUser();
    const body = await request.json();

    const input = validate(createInventorySchema, body);

    const inventory = await InventoryService.createInventory(
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "inventory:create",
      entity: "inventory",
      entityId: inventory.id,
      meta: {
        store_id: inventory.store_id,
        product_id: inventory.product_id,
        min_stock: inventory.min_stock,
        max_stock: inventory.max_stock,
      },
    });

    return NextResponse.json(inventory, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}
