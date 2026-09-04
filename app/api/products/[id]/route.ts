import { NextResponse } from "next/server";

import { ProductsService } from "@/lib/products/products.service";
import { AuditService } from "@/lib/audit/audit.service";
import { getCurrentUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { updateProductSchema } from "@/features/products/validation/product.schema";

type Params = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const { id } = await params;

    const product = await ProductsService.getProduct(id);

    return NextResponse.json(product);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: Params) {
  try {
    const { id } = await params;

    const body = await request.json();
    const input = updateProductSchema.parse(body);

    const product = await ProductsService.updateProduct(id, input);

    const currentUser = await getCurrentUser();

    if (currentUser) {
      await AuditService.log({
        userId: currentUser.id,
        action: "product:update",
        entity: "products",
        entityId: product.id,
        meta: {
          name: product.name,
          sku: product.sku,
          is_active: product.is_active,
        },
      });
    }

    return NextResponse.json(product);
  } catch (error) {
    return handleApiError(error);
  }
}
