import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { StoresService } from "@/lib/stores/stores.service";
import { createStoreSchema } from "@/features/stores/validation/store.schema";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const stores = await StoresService.getStores(currentUser);

    return NextResponse.json(stores);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();
    const body = await request.json();

    const input = validate(createStoreSchema, body);

    const store = await StoresService.createStore(input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "store:create",
      entity: "store",
      entityId: store.id,
      meta: {
        name: store.name,
        city: store.city,
      },
    });

    return NextResponse.json(store, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
