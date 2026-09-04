import { NextResponse } from "next/server";

import { ProductsService } from "@/lib/products/products.service";
import { AuditService } from "@/lib/audit/audit.service";
import { getCurrentUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { createProductSchema } from "@/features/products/validation/product.schema";

export async function GET() {
  try {
    const products = await ProductsService.getProducts();

    return NextResponse.json(products);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const input = createProductSchema.parse(body);

    const product = await ProductsService.createProduct(input);

    const currentUser = await getCurrentUser();

    if (currentUser) {
      await AuditService.log({
        userId: currentUser.id,
        action: "product:create",
        entity: "products",
        entityId: product.id,
        meta: {
          name: product.name,
          sku: product.sku,
        },
      });
    }

    return NextResponse.json(product, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
