import { sql } from "@/db";
import type { CurrentUser } from "@/features/auth";
import { LOGISTICS_ROUTE_TEXT } from "@/features/logistics-routes/constants/logistics-route-text";
import type {
  CreateLogisticsRouteInput,
  LogisticsRoute,
  UpdateLogisticsRouteInput,
} from "@/features/logistics-routes/types";
import { PERMISSIONS, hasPermission } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError } from "@/lib/errors";

type LogisticsRouteRow = LogisticsRoute;

export class LogisticsRoutesService {
  static async getLogisticsRoutes(
    currentUser: CurrentUser,
  ): Promise<LogisticsRoute[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        store_a_id,
        store_b_id,
        distance_km,
        estimated_duration_minutes,
        is_active,
        created_at,
        updated_at
      FROM logistics_routes
      WHERE is_active = TRUE
      ORDER BY store_a_id, store_b_id
    `) as LogisticsRouteRow[];

    return rows;
  }

  static async getLogisticsRouteById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<LogisticsRoute> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        store_a_id,
        store_b_id,
        distance_km,
        estimated_duration_minutes,
        is_active,
        created_at,
        updated_at
      FROM logistics_routes
      WHERE id = ${id}
      LIMIT 1
    `) as LogisticsRouteRow[];

    if (!rows.length) {
      throw new NotFoundError(LOGISTICS_ROUTE_TEXT.error.empty_route);
    }

    return rows[0];
  }

  static async createLogisticsRoute(
    data: CreateLogisticsRouteInput,
    currentUser: CurrentUser,
  ): Promise<LogisticsRoute> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.forbidden_create);
    }

    if (data.store_a_id === data.store_b_id) {
      throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.stores_must_differ);
    }

    const storeRows = await sql`
      SELECT id
      FROM stores
      WHERE id IN (${data.store_a_id}, ${data.store_b_id})
        AND is_active = TRUE
    `;

    if (storeRows.length !== 2) {
      throw new NotFoundError(LOGISTICS_ROUTE_TEXT.error.store_not_found);
    }

    const [storeAId, storeBId] =
      data.store_a_id < data.store_b_id
        ? [data.store_a_id, data.store_b_id]
        : [data.store_b_id, data.store_a_id];

    try {
      const rows = (await sql`
        INSERT INTO logistics_routes (
          store_a_id,
          store_b_id,
          distance_km,
          estimated_duration_minutes
        )
        VALUES (
          ${storeAId},
          ${storeBId},
          ${data.distance_km},
          ${data.estimated_duration_minutes ?? null}
        )
        RETURNING
          id,
          store_a_id,
          store_b_id,
          distance_km,
          estimated_duration_minutes,
          is_active,
          created_at,
          updated_at
      `) as LogisticsRouteRow[];

      return rows[0];
    } catch (error) {
      if (this.isUniqueViolation(error)) {
        throw new ValidationError(
          LOGISTICS_ROUTE_TEXT.error.route_already_exists,
        );
      }

      if (this.isCheckViolation(error)) {
        throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.invalid_distance);
      }

      throw error;
    }
  }

  static async updateLogisticsRoute(
    id: string,
    data: UpdateLogisticsRouteInput,
    currentUser: CurrentUser,
  ): Promise<LogisticsRoute> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.forbidden_update);
    }

    const existingRows = (await sql`
      SELECT
        id,
        store_a_id,
        store_b_id,
        distance_km,
        estimated_duration_minutes,
        is_active,
        created_at,
        updated_at
      FROM logistics_routes
      WHERE id = ${id}
      LIMIT 1
    `) as LogisticsRouteRow[];

    if (!existingRows.length) {
      throw new NotFoundError(LOGISTICS_ROUTE_TEXT.error.empty_route);
    }

    const route = existingRows[0];

    const distanceKm =
      data.distance_km !== undefined ? data.distance_km : route.distance_km;

    const estimatedDuration =
      data.estimated_duration_minutes !== undefined
        ? data.estimated_duration_minutes
        : route.estimated_duration_minutes;

    const isActive =
      data.is_active !== undefined ? data.is_active : route.is_active;

    try {
      const rows = (await sql`
        UPDATE logistics_routes
        SET
          distance_km = ${distanceKm},
          estimated_duration_minutes = ${estimatedDuration},
          is_active = ${isActive},
          updated_at = NOW()
        WHERE id = ${id}
        RETURNING
          id,
          store_a_id,
          store_b_id,
          distance_km,
          estimated_duration_minutes,
          is_active,
          created_at,
          updated_at
      `) as LogisticsRouteRow[];

      if (!rows.length) {
        throw new NotFoundError(LOGISTICS_ROUTE_TEXT.error.empty_route);
      }

      return rows[0];
    } catch (error) {
      if (this.isCheckViolation(error)) {
        throw new ValidationError(LOGISTICS_ROUTE_TEXT.error.invalid_distance);
      }

      throw error;
    }
  }

  private static isUniqueViolation(error: unknown): boolean {
    return (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "23505"
    );
  }

  private static isCheckViolation(error: unknown): boolean {
    return (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "23514"
    );
  }
}
