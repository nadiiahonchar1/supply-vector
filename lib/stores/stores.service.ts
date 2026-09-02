import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/server";
import { PERMISSIONS, hasPermission } from "@/lib/auth/permissions";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type {
  Store,
  CreateStoreInput,
  UpdateStoreInput,
} from "@/features/stores/types";

import { STORES_TEXT } from "@/features/stores/constants/stores-text";

type StoreRow = Store;

export class StoresService {
  private static async requireCurrentUser() {
    const currentUser = await getCurrentUser();

    if (!currentUser) {
      throw new ForbiddenError();
    }

    return currentUser;
  }

  private static requirePermission(
    role: Parameters<typeof hasPermission>[0],
    permission: Parameters<typeof hasPermission>[1],
    errorMessage?: string,
  ) {
    if (!hasPermission(role, permission)) {
      throw new ForbiddenError(errorMessage);
    }
  }

  static async getStores(): Promise<Store[]> {
    const currentUser = await this.requireCurrentUser();

    this.requirePermission(currentUser.role, PERMISSIONS.STORE_VIEW);

    const stores = (await sql`
      SELECT
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM stores
      ORDER BY name, city
    `) as StoreRow[];

    return stores;
  }

  static async getStore(id: string): Promise<Store> {
    const currentUser = await this.requireCurrentUser();

    this.requirePermission(currentUser.role, PERMISSIONS.STORE_VIEW);

    const stores = (await sql`
      SELECT
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM stores
      WHERE id = ${id}
      LIMIT 1
    `) as StoreRow[];

    if (!stores.length) {
      throw new NotFoundError(STORES_TEXT.error.empty_store);
    }

    return stores[0];
  }

  static async createStore(data: CreateStoreInput): Promise<Store> {
    const currentUser = await this.requireCurrentUser();

    this.requirePermission(
      currentUser.role,
      PERMISSIONS.STORE_CREATE,
      STORES_TEXT.error.forbidden_create,
    );

    const existing = (await sql`
      SELECT id
      FROM stores
      WHERE
        name = ${data.name}
        AND city = ${data.city}
        AND address = ${data.address}
      LIMIT 1
    `) as { id: string }[];

    if (existing.length) {
      throw new ValidationError(STORES_TEXT.error.duplicate);
    }

    const storeId = crypto.randomUUID();

    const stores = (await sql`
      INSERT INTO stores (
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        created_by,
        updated_by
      )
      VALUES (
        ${storeId},
        ${data.name},
        ${data.city},
        ${data.address},
        ${data.latitude ?? null},
        ${data.longitude ?? null},
        ${data.is_storage_node ?? true},
        ${data.max_capacity ?? null},
        ${currentUser.id},
        ${currentUser.id}
      )
      RETURNING
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as StoreRow[];

    return stores[0];
  }

  static async updateStore(id: string, data: UpdateStoreInput): Promise<Store> {
    const currentUser = await this.requireCurrentUser();

    this.requirePermission(
      currentUser.role,
      PERMISSIONS.STORE_UPDATE,
      STORES_TEXT.error.forbidden_update,
    );

    await this.getStore(id);

    const name = data.name;
    const city = data.city;
    const address = data.address;
    const latitude = data.latitude;
    const longitude = data.longitude;
    const isStorageNode = data.is_storage_node;
    const maxCapacity = data.max_capacity;

    if (name !== undefined || city !== undefined || address !== undefined) {
      const existing = (await sql`
        SELECT id
        FROM stores
        WHERE
          name = COALESCE(${name ?? null}, name)
          AND city = COALESCE(${city ?? null}, city)
          AND address = COALESCE(${address ?? null}, address)
          AND id <> ${id}
        LIMIT 1
      `) as { id: string }[];

      if (existing.length) {
        throw new ValidationError(STORES_TEXT.error.duplicate);
      }
    }

    const stores = (await sql`
      UPDATE stores
      SET
        name = COALESCE(${name ?? null}, name),
        city = COALESCE(${city ?? null}, city),
        address = COALESCE(${address ?? null}, address),
        latitude = COALESCE(${latitude ?? null}, latitude),
        longitude = COALESCE(${longitude ?? null}, longitude),
        is_storage_node = COALESCE(
          ${isStorageNode ?? null},
          is_storage_node
        ),
        max_capacity = COALESCE(
          ${maxCapacity ?? null},
          max_capacity
        ),
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE id = ${id}
      RETURNING
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as StoreRow[];

    if (!stores.length) {
      throw new NotFoundError(STORES_TEXT.error.empty_store);
    }

    return stores[0];
  }
}
