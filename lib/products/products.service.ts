import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/server";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type {
  Product,
  CreateProductInput,
  UpdateProductInput,
} from "@/features/products/types";

import { PRODUCT_TEXT } from "@/features/products/constants/product-text";

type ProductRow = Product;

export class ProductsService {
  private static async requireCurrentUser() {
    const currentUser = await getCurrentUser();

    if (!currentUser) {
      throw new ForbiddenError();
    }

    return currentUser;
  }

  static async getProducts(): Promise<Product[]> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_VIEW)) {
      throw new ForbiddenError();
    }

    return (await sql`
      SELECT
        id,
        name,
        sku,
        price,
        description,
        weight_kg,
        volume_m3,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM products
      ORDER BY name
    `) as ProductRow[];
  }

  static async getProduct(id: string): Promise<Product> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_VIEW)) {
      throw new ForbiddenError();
    }

    const products = (await sql`
      SELECT
        id,
        name,
        sku,
        price,
        description,
        weight_kg,
        volume_m3,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM products
      WHERE id = ${id}
      LIMIT 1
    `) as ProductRow[];

    if (!products.length) {
      throw new NotFoundError(PRODUCT_TEXT.error.empty_product);
    }

    return products[0];
  }

  static async createProduct(data: CreateProductInput): Promise<Product> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_CREATE)) {
      throw new ForbiddenError(PRODUCT_TEXT.error.forbidden_create);
    }

    const existing = (await sql`
      SELECT id
      FROM products
      WHERE sku = ${data.sku}
      LIMIT 1
    `) as { id: string }[];

    if (existing.length) {
      throw new ValidationError(PRODUCT_TEXT.error.duplicate_sku);
    }

    const productId = crypto.randomUUID();

    const products = (await sql`
      INSERT INTO products (
        id,
        name,
        sku,
        price,
        description,
        weight_kg,
        volume_m3,
        is_active,
        created_by,
        updated_by
      )
      VALUES (
        ${productId},
        ${data.name},
        ${data.sku},
        ${data.price},
        ${data.description ?? null},
        ${data.weight_kg ?? null},
        ${data.volume_m3 ?? null},
        TRUE,
        ${currentUser.id},
        ${currentUser.id}
      )
      RETURNING
        id,
        name,
        sku,
        price,
        description,
        weight_kg,
        volume_m3,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as ProductRow[];

    return products[0];
  }

  static async updateProduct(
    id: string,
    data: UpdateProductInput,
  ): Promise<Product> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_UPDATE)) {
      throw new ForbiddenError(PRODUCT_TEXT.error.forbidden_update);
    }

    const existingProduct = await this.getProduct(id);

    const name = data.name ?? existingProduct.name;
    const sku = data.sku ?? existingProduct.sku;
    const price = data.price ?? existingProduct.price;

    const description =
      data.description !== undefined
        ? data.description
        : existingProduct.description;

    const weightKg =
      data.weight_kg !== undefined ? data.weight_kg : existingProduct.weight_kg;

    const volumeM3 =
      data.volume_m3 !== undefined ? data.volume_m3 : existingProduct.volume_m3;

    const isActive =
      data.is_active !== undefined ? data.is_active : existingProduct.is_active;

    const duplicate = (await sql`
      SELECT id
      FROM products
      WHERE
        sku = ${sku}
        AND id <> ${id}
      LIMIT 1
    `) as { id: string }[];

    if (duplicate.length) {
      throw new ValidationError(PRODUCT_TEXT.error.duplicate_sku);
    }

    const products = (await sql`
      UPDATE products
      SET
        name = ${name},
        sku = ${sku},
        price = ${price},
        description = ${description},
        weight_kg = ${weightKg},
        volume_m3 = ${volumeM3},
        is_active = ${isActive},
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE id = ${id}
      RETURNING
        id,
        name,
        sku,
        price,
        description,
        weight_kg,
        volume_m3,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as ProductRow[];

    if (!products.length) {
      throw new NotFoundError(PRODUCT_TEXT.error.empty_product);
    }

    return products[0];
  }
}
