import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation/validate";

import { ProductsService } from "@/lib/products/products.service";
import { createProductSchema } from "@/features/products/validation/product.schema";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const products = await ProductsService.getProducts(currentUser);

    return NextResponse.json(products);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();
    const body = await request.json();

    const input = validate(createProductSchema, body);

    const product = await ProductsService.createProduct(input, currentUser);

    await AuditService.log({
      userId: currentUser.id,
      action: "product:create",
      entity: "product",
      entityId: product.id,
      meta: {
        name: product.name,
        sku: product.sku,
      },
    });

    return NextResponse.json(product, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
