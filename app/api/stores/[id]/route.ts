import { NextResponse } from "next/server";

import { StoresService } from "@/lib/stores/stores.service";
import { AuditService } from "@/lib/audit/audit.service";
import { getCurrentUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { updateStoreSchema } from "@/features/stores/validation/store.schema";

type Params = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const { id } = await params;

    const store = await StoresService.getStore(id);

    return NextResponse.json(store);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const { id } = await params;

    const body = await request.json();
    const input = updateStoreSchema.parse(body);

    const store = await StoresService.updateStore(id, input);

    const currentUser = await getCurrentUser();

    if (currentUser) {
      await AuditService.log({
        userId: currentUser.id,
        action: "store:update",
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

    return NextResponse.json(store);
  } catch (error) {
    return handleApiError(error);
  }
}
