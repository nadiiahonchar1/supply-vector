import { NextRequest, NextResponse } from "next/server";

import {
  createInventorySchema,
  inventoryFiltersSchema,
} from "@/features/inventory";
import { InventoryService } from "@/lib/inventory";
import { AuditService } from "@/lib/audit";
import { validate } from "@/lib/validation";
import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";

export async function GET(request: NextRequest) {
  try {
    const currentUser = await requireUser();
    const searchParams = request.nextUrl.searchParams;

    const input = validate(inventoryFiltersSchema, {
      store_id: searchParams.get("store_id") ?? undefined,
      product_id: searchParams.get("product_id") ?? undefined,
      city: searchParams.get("city") ?? undefined,
      low_stock: searchParams.get("low_stock") ?? undefined,
    });

    const filters = {
      ...input,
      low_stock:
        input.low_stock === undefined ? undefined : input.low_stock === "true",
    };

    const inventory = await InventoryService.getInventory(currentUser, filters);

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
