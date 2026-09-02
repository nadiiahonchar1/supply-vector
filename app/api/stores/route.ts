import { NextResponse } from "next/server";

import { StoresService } from "@/lib/stores/stores.service";
import { AuditService } from "@/lib/audit/audit.service";
import { getCurrentUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { createStoreSchema } from "@/features/stores/validation/store.schema";

export async function GET() {
  try {
    const stores = await StoresService.getStores();

    return NextResponse.json(stores);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(req: Request) {
  try {
    const body = await req.json();

    const input = createStoreSchema.parse(body);

    const store = await StoresService.createStore(input);

    const currentUser = await getCurrentUser();

    if (currentUser) {
      await AuditService.log({
        userId: currentUser.id,
        action: "store:create",
        entity: "stores",
        entityId: store.id,
        meta: {
          name: store.name,
          city: store.city,
          address: store.address,
          is_storage_node: store.is_storage_node,
        },
      });
    }

    return NextResponse.json(store, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}
