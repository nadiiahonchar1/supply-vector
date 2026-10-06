import { sql } from "@/db";
import type { CurrentUser } from "@/features/auth";
import type {
  CreateInventoryInput,
  Inventory,
  InventoryWithDetails,
  UpdateInventoryInput,
  AdjustInventoryInput,
} from "@/features/inventory/types";
import { PERMISSIONS, hasPermission } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";
// import { ApiError } from "@/lib/errors/api-error";
import { INVENTORY_TEXT } from "@/features/inventory/constants/inventory-text";

export class InventoryService {
  static async getInventory(
    currentUser: CurrentUser,
  ): Promise<InventoryWithDetails[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_VIEW)) {
      throw new ForbiddenError();
    }

    const result = await sql`
      SELECT
        i.id,
        i.store_id,
        i.product_id,
        i.quantity,
        i.reserved_quantity,
        i.min_stock,
        i.max_stock,
        i.created_at,
        i.updated_at,

        s.name AS store_name,
        s.city,

        p.name AS product_name,
        p.sku

      FROM inventory i
      JOIN stores s
        ON s.id = i.store_id
      JOIN products p
        ON p.id = i.product_id

      ORDER BY s.name, p.name
    `;

    return result as InventoryWithDetails[];
  }

  static async getInventoryById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Inventory> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_VIEW)) {
      throw new ForbiddenError();
    }

    const result = await sql`
      SELECT
        id,
        store_id,
        product_id,
        quantity,
        reserved_quantity,
        min_stock,
        max_stock,
        created_at,
        updated_at
      FROM inventory
      WHERE id = ${id}
      LIMIT 1
    `;

    const inventory = result[0] as Inventory | undefined;

      if (!inventory) {
        throw new NotFoundError(INVENTORY_TEXT.error.empty_inventory);
    }

    return inventory;
  }

  static async createInventory(
    data: CreateInventoryInput,
    currentUser: CurrentUser,
  ): Promise<Inventory> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_ADJUST)) {
      throw new ForbiddenError();
    }

    const storeResult = await sql`
      SELECT
        id,
        is_active,
        is_storage_node
      FROM stores
      WHERE id = ${data.store_id}
      LIMIT 1
    `;

    const store = storeResult[0] as
      | {
          id: string;
          is_active: boolean;
          is_storage_node: boolean;
        }
      | undefined;

    if (!store) {
        throw new NotFoundError(INVENTORY_TEXT.error.store_not_found);
    }

    if (!store.is_active) {
        throw new ValidationError(INVENTORY_TEXT.error.store_inactive);
    }

    if (!store.is_storage_node) {
        throw new ValidationError(INVENTORY_TEXT.error.store_not_storage_node);
    }

    const productResult = await sql`
      SELECT
        id,
        is_active
      FROM products
      WHERE id = ${data.product_id}
      LIMIT 1
    `;

    const product = productResult[0] as
      | {
          id: string;
          is_active: boolean;
        }
      | undefined;

      if (!product) {
          throw new NotFoundError(INVENTORY_TEXT.error.product_not_found);
    }

    if (!product.is_active) {
        throw new ValidationError(INVENTORY_TEXT.error.product_inactive);
    }

    if (
      data.max_stock !== null &&
      data.max_stock !== undefined &&
      data.min_stock !== undefined &&
      data.max_stock < data.min_stock
    ) {
        throw new ValidationError(
          INVENTORY_TEXT.error.max_stock_less_than_min_stock);      
    }

    try {
      const result = await sql`
        INSERT INTO inventory (
          store_id,
          product_id,
          quantity,
          reserved_quantity,
          min_stock,
          max_stock,
          created_at,
          updated_at
        )
        VALUES (
          ${data.store_id},
          ${data.product_id},
          0,
          0,
          ${data.min_stock ?? 0},
          ${data.max_stock ?? null},
          NOW(),
          NOW()
        )
        RETURNING
          id,
          store_id,
          product_id,
          quantity,
          reserved_quantity,
          min_stock,
          max_stock,
          created_at,
          updated_at
      `;

      return result[0] as Inventory;
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "23505") {          
          throw new ValidationError(INVENTORY_TEXT.error.inventory_already_exists);
      }

      throw error;
    }
  }

  static async updateInventory(
    id: string,
    data: UpdateInventoryInput,
    currentUser: CurrentUser,
  ): Promise<Inventory> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_ADJUST)) {
      throw new ForbiddenError();
    }

    if (data.min_stock === undefined && data.max_stock === undefined) {       
        throw new ValidationError(INVENTORY_TEXT.error.invalid_min_stock);
    }

    const currentResult = await sql`
      SELECT
        id,
        min_stock,
        max_stock
      FROM inventory
      WHERE id = ${id}
      LIMIT 1
    `;

    const current = currentResult[0] as
      | {
          id: string;
          min_stock: number;
          max_stock: number | null;
        }
      | undefined;

    if (!current) {
      throw new NotFoundError(INVENTORY_TEXT.error.empty_inventory);
    }

    const minStock = data.min_stock ?? current.min_stock;

    const maxStock =
      data.max_stock !== undefined ? data.max_stock : current.max_stock;

    if (maxStock !== null && maxStock < minStock) {      
        throw new ValidationError(INVENTORY_TEXT.error.max_stock_less_than_min_stock);
    }

    const result = await sql`
      UPDATE inventory
      SET
        min_stock = ${minStock},
        max_stock = ${maxStock},
        updated_at = NOW()
      WHERE id = ${id}
      RETURNING
        id,
        store_id,
        product_id,
        quantity,
        reserved_quantity,
        min_stock,
        max_stock,
        created_at,
        updated_at
    `;

    return result[0] as Inventory;
  }

  static async adjustInventory(
    id: string,
    data: AdjustInventoryInput,
    currentUser: CurrentUser,
  ): Promise<Inventory> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_ADJUST)) {
      throw new ForbiddenError();
    }

    const result = await sql`
      WITH updated_inventory AS (
        UPDATE inventory
        SET
          quantity = quantity + ${data.quantity_change},
          updated_at = NOW()
        WHERE id = ${id}
          AND quantity + ${data.quantity_change} >= 0
          AND (
            max_stock IS NULL
            OR quantity + ${data.quantity_change} <= max_stock
          )
        RETURNING
          id,
          store_id,
          product_id,
          quantity - ${data.quantity_change}
            AS quantity_before,
          quantity AS quantity_after,
          quantity,
          reserved_quantity,
          min_stock,
          max_stock,
          created_at,
          updated_at
      ),

      created_movement AS (
        INSERT INTO inventory_movements (
          store_id,
          product_id,
          quantity_change,
          quantity_before,
          quantity_after,
          movement_type,
          created_by,
          created_at
        )
        SELECT
          store_id,
          product_id,
          ${data.quantity_change},
          quantity_before,
          quantity_after,
          ${data.movement_type},
          ${currentUser.id},
          NOW()
        FROM updated_inventory
        RETURNING id
      )

      SELECT
        ui.id,
        ui.store_id,
        ui.product_id,
        ui.quantity,
        ui.reserved_quantity,
        ui.min_stock,
        ui.max_stock,
        ui.created_at,
        ui.updated_at
      FROM updated_inventory ui
      LEFT JOIN created_movement cm
        ON TRUE
    `;

    if (result.length === 0) {
      const inventoryResult = await sql`
        SELECT
          id,
          quantity,
          reserved_quantity,
          max_stock
        FROM inventory
        WHERE id = ${id}
        LIMIT 1
      `;

      if (inventoryResult.length === 0) {
        throw new NotFoundError(INVENTORY_TEXT.error.empty_inventory);
      }

      const inventory = inventoryResult[0] as {
        id: string;
        quantity: number;
        reserved_quantity: number;
        max_stock: number | null;
      };

      if (
        data.quantity_change < 0 &&
        inventory.quantity + data.quantity_change < 0
      ) {         
          throw new NotFoundError(INVENTORY_TEXT.error.insufficient_quantity);
      }

      if (
        data.quantity_change > 0 &&
        inventory.max_stock !== null &&
        inventory.quantity + data.quantity_change > inventory.max_stock
      ) {
          throw new NotFoundError(INVENTORY_TEXT.error.invalid_quantity_change);
      }

      throw new NotFoundError(INVENTORY_TEXT.error.invalid_quantity_change);
    }

    return result[0] as Inventory;
  }
}
