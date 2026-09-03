import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/server";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
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

  static async getStores(): Promise<Store[]> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_VIEW)) {
      throw new ForbiddenError();
    }

    return (await sql`
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
  }

  static async getStore(id: string): Promise<Store> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_VIEW)) {
      throw new ForbiddenError();
    }

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

    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_CREATE)) {
      throw new ForbiddenError(STORES_TEXT.error.forbidden_create);
    }

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

    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_UPDATE)) {
      throw new ForbiddenError(STORES_TEXT.error.forbidden_update);
    }

    const existingStore = await this.getStore(id);

    const name = data.name ?? existingStore.name;
    const city = data.city ?? existingStore.city;
    const address = data.address ?? existingStore.address;

    const duplicate = (await sql`
      SELECT id
      FROM stores
      WHERE
        name = ${name}
        AND city = ${city}
        AND address = ${address}
        AND id <> ${id}
      LIMIT 1
    `) as { id: string }[];

    if (duplicate.length) {
      throw new ValidationError(STORES_TEXT.error.duplicate);
    }

    const latitude =
      data.latitude !== undefined ? data.latitude : existingStore.latitude;

    const longitude =
      data.longitude !== undefined ? data.longitude : existingStore.longitude;

    const isStorageNode =
      data.is_storage_node !== undefined
        ? data.is_storage_node
        : existingStore.is_storage_node;

    const maxCapacity =
      data.max_capacity !== undefined
        ? data.max_capacity
        : existingStore.max_capacity;

    const stores = (await sql`
      UPDATE stores
      SET
        name = ${name},
        city = ${city},
        address = ${address},
        latitude = ${latitude},
        longitude = ${longitude},
        is_storage_node = ${isStorageNode},
        max_capacity = ${maxCapacity},
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
