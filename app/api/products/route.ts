import { NextResponse } from "next/server";

import { createProductSchema } from "@/features/products";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { ProductsService } from "@/lib/products";

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
