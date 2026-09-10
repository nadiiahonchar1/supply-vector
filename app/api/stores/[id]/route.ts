import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { StoresService } from "@/lib/stores/stores.service";
import { updateStoreSchema } from "@/features/stores/validation/store.schema";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const store = await StoresService.getStoreById(id, currentUser);

    return NextResponse.json(store);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;
    const body = await request.json();

    const input = validate(updateStoreSchema, body);

    const store = await StoresService.updateStore(id, input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "store:update",
      entity: "store",
      entityId: store.id,
      meta: {
        name: store.name,
        city: store.city,
      },
    });

    return NextResponse.json(store);
  } catch (error) {
    return handleApiError(error);
  }
}
