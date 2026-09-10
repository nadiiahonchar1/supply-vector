import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { ProductsService } from "@/lib/products/products.service";
import { updateProductSchema } from "@/features/products/validation/product.schema";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const product = await ProductsService.getProductById(id, currentUser);

    return NextResponse.json(product);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;
    const body = await request.json();

    const input = validate(updateProductSchema, body);

    const product = await ProductsService.updateProduct(id, input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "product:update",
      entity: "product",
      entityId: product.id,
      meta: {
        name: product.name,
        sku: product.sku,
      },
    });

    return NextResponse.json(product);
  } catch (error) {
    return handleApiError(error);
  }
}
