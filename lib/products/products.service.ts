import { sql } from "@/db";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth/types";

import type {
  Product,
  CreateProductInput,
  UpdateProductInput,
} from "@/features/products/types";

import { PRODUCT_TEXT } from "@/features/products/constants/product-text";

type ProductRow = {
  id: string;
  name: string;
  sku: string;
  price: number;
  description: string | null;
  weight_kg: number | null;
  volume_m3: number | null;
  is_active: boolean;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
};

export class ProductsService {
  static async getProducts(currentUser: CurrentUser): Promise<Product[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
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
      WHERE is_active = TRUE
      ORDER BY name
    `) as ProductRow[];

    return rows;
  }

  static async getProductById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Product> {
    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
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

    if (!rows.length) {
      throw new NotFoundError(PRODUCT_TEXT.error.empty_product);
    }

    return rows[0];
  }

  static async createProduct(
    data: CreateProductInput,
    currentUser: CurrentUser,
  ): Promise<Product> {
    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_CREATE)) {
      throw new ForbiddenError(PRODUCT_TEXT.error.forbidden_create);
    }

    const existing = await sql`
      SELECT id
      FROM products
      WHERE sku = ${data.sku}
      LIMIT 1
    `;

    if (existing.length) {
      throw new ValidationError(PRODUCT_TEXT.error.duplicate_sku);
    }

    const productId = crypto.randomUUID();

    const rows = (await sql`
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

    return rows[0];
  }

  static async updateProduct(
    id: string,
    data: UpdateProductInput,
    currentUser: CurrentUser,
  ): Promise<Product> {
    if (!hasPermission(currentUser.role, PERMISSIONS.PRODUCT_UPDATE)) {
      throw new ForbiddenError(PRODUCT_TEXT.error.forbidden_update);
    }

    const existing = await this.getProductById(id, currentUser);

    const name = data.name !== undefined ? data.name : existing.name;

    const sku = data.sku !== undefined ? data.sku : existing.sku;

    const duplicate = await sql`
      SELECT id
      FROM products
      WHERE sku = ${sku}
        AND id <> ${id}
      LIMIT 1
    `;

    if (duplicate.length) {
      throw new ValidationError(PRODUCT_TEXT.error.duplicate_sku);
    }

    const price = data.price !== undefined ? data.price : existing.price;

    const description =
      data.description !== undefined ? data.description : existing.description;

    const weightKg =
      data.weight_kg !== undefined ? data.weight_kg : existing.weight_kg;

    const volumeM3 =
      data.volume_m3 !== undefined ? data.volume_m3 : existing.volume_m3;

    const isActive =
      data.is_active !== undefined ? data.is_active : existing.is_active;

    const rows = (await sql`
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

    if (!rows.length) {
      throw new NotFoundError(PRODUCT_TEXT.error.empty_product);
    }

    return rows[0];
  }
}
