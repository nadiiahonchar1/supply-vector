import { sql } from "@/db";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth/types";

import type {
  Store,
  CreateStoreInput,
  UpdateStoreInput,
} from "@/features/stores/types";

import { STORES_TEXT } from "@/features/stores/constants/stores-text";

type StoreRow = {
  id: string;
  name: string;
  city: string;
  address: string;
  latitude: string | number | null;
  longitude: string | number | null;
  is_storage_node: boolean;
  max_capacity: string | number | null;
  is_active: boolean;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
};

function normalizeStore(row: StoreRow): Store {
  return {
    ...row,
    latitude: row.latitude !== null ? Number(row.latitude) : null,
    longitude: row.longitude !== null ? Number(row.longitude) : null,
    max_capacity: row.max_capacity !== null ? Number(row.max_capacity) : null,
  };
}

export class StoresService {
  static async getStores(currentUser: CurrentUser): Promise<Store[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM stores
      WHERE is_active = TRUE
      ORDER BY name, city, address
    `) as StoreRow[];

    return rows.map(normalizeStore);
  }

  static async getStore(id: string, currentUser: CurrentUser): Promise<Store> {
    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM stores
      WHERE id = ${id}
      LIMIT 1
    `) as StoreRow[];

    if (!rows.length) {
      throw new NotFoundError(STORES_TEXT.error.empty_store);
    }

    return normalizeStore(rows[0]);
  }

  static async createStore(
    data: CreateStoreInput,
    currentUser: CurrentUser,
  ): Promise<Store> {
    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_CREATE)) {
      throw new ForbiddenError(STORES_TEXT.error.forbidden_create);
    }

    const existing = await sql`
      SELECT id
      FROM stores
      WHERE name = ${data.name}
        AND city = ${data.city}
        AND address = ${data.address}
      LIMIT 1
    `;

    if (existing.length) {
      throw new ValidationError(STORES_TEXT.error.duplicate);
    }

    const storeId = crypto.randomUUID();

    const rows = (await sql`
      INSERT INTO stores (
        id,
        name,
        city,
        address,
        latitude,
        longitude,
        is_storage_node,
        max_capacity,
        is_active,
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
        TRUE,
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
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as StoreRow[];

    return normalizeStore(rows[0]);
  }

  static async updateStore(
    id: string,
    data: UpdateStoreInput,
    currentUser: CurrentUser,
  ): Promise<Store> {
    if (!hasPermission(currentUser.role, PERMISSIONS.STORE_UPDATE)) {
      throw new ForbiddenError(STORES_TEXT.error.forbidden_update);
    }

    const existing = await this.getStore(id, currentUser);

    const name = data.name !== undefined ? data.name : existing.name;

    const city = data.city !== undefined ? data.city : existing.city;

    const address =
      data.address !== undefined ? data.address : existing.address;

    const duplicate = await sql`
      SELECT id
      FROM stores
      WHERE name = ${name}
        AND city = ${city}
        AND address = ${address}
        AND id <> ${id}
      LIMIT 1
    `;

    if (duplicate.length) {
      throw new ValidationError(STORES_TEXT.error.duplicate);
    }

    const latitude =
      data.latitude !== undefined ? data.latitude : existing.latitude;

    const longitude =
      data.longitude !== undefined ? data.longitude : existing.longitude;

    const isStorageNode =
      data.is_storage_node !== undefined
        ? data.is_storage_node
        : existing.is_storage_node;

    const maxCapacity =
      data.max_capacity !== undefined
        ? data.max_capacity
        : existing.max_capacity;

    const isActive =
      data.is_active !== undefined ? data.is_active : existing.is_active;

    const rows = (await sql`
      UPDATE stores
      SET
        name = ${name},
        city = ${city},
        address = ${address},
        latitude = ${latitude},
        longitude = ${longitude},
        is_storage_node = ${isStorageNode},
        max_capacity = ${maxCapacity},
        is_active = ${isActive},
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
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as StoreRow[];

    if (!rows.length) {
      throw new NotFoundError(STORES_TEXT.error.empty_store);
    }

    return normalizeStore(rows[0]);
  }
}
