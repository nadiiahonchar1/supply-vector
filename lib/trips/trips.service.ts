import { sql } from "@/db";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import type { CurrentUser } from "@/features/auth/types";
import type {
  CreateTripInput,
  Trip,
  TripStatus,
  UpdateTripInput,
} from "@/features/trips/types";
import { TRIP_TEXT } from "@/features/trips/constants/trip-text";
import { NotFoundError, ValidationError } from "@/lib/errors";

type TripRow = Trip;

export class TripsService {
  static async getTrips(currentUser: CurrentUser): Promise<Trip[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ValidationError(TRIP_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        vehicle_id,
        origin_store_id,
        status,
        departure_at,
        expected_arrival_at,
        distance_km,
        cost,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM trips
      ORDER BY created_at DESC
    `) as TripRow[];

    return rows;
  }

  static async getTripById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Trip> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ValidationError(TRIP_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        vehicle_id,
        origin_store_id,
        status,
        departure_at,
        expected_arrival_at,
        distance_km,
        cost,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM trips
      WHERE id = ${id}
      LIMIT 1
    `) as TripRow[];

    if (!rows.length) {
      throw new NotFoundError(TRIP_TEXT.error.empty_trip);
    }

    return rows[0];
  }

  static async createTrip(
    data: CreateTripInput,
    currentUser: CurrentUser,
  ): Promise<Trip> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_CREATE)) {
      throw new ValidationError(TRIP_TEXT.error.forbidden_create);
    }

    if (
      data.departure_at &&
      data.expected_arrival_at &&
      new Date(data.expected_arrival_at) < new Date(data.departure_at)
    ) {
      throw new ValidationError(TRIP_TEXT.error.invalid_time_window);
    }

    const vehicleRows = await sql`
      SELECT id
      FROM vehicles
      WHERE id = ${data.vehicle_id}
        AND is_active = TRUE
      LIMIT 1
    `;

    if (!vehicleRows.length) {
      throw new NotFoundError(TRIP_TEXT.error.vehicle_not_found);
    }

    const storeRows = await sql`
      SELECT id
      FROM stores
      WHERE id = ${data.origin_store_id}
        AND is_active = TRUE
      LIMIT 1
    `;

    if (!storeRows.length) {
      throw new NotFoundError(TRIP_TEXT.error.origin_store_not_found);
    }

    const rows = (await sql`
      INSERT INTO trips (
        vehicle_id,
        origin_store_id,
        status,
        departure_at,
        expected_arrival_at,
        distance_km,
        cost,
        created_by,
        updated_by,
        created_at,
        updated_at
      )
      VALUES (
        ${data.vehicle_id},
        ${data.origin_store_id},
        'planned',
        ${data.departure_at ?? null},
        ${data.expected_arrival_at ?? null},
        ${data.distance_km ?? null},
        ${data.cost ?? null},
        ${currentUser.id},
        ${currentUser.id},
        NOW(),
        NOW()
      )
      RETURNING
        id,
        vehicle_id,
        origin_store_id,
        status,
        departure_at,
        expected_arrival_at,
        distance_km,
        cost,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as TripRow[];

    return rows[0];
  }

  static async updateTrip(
    id: string,
    data: UpdateTripInput,
    currentUser: CurrentUser,
  ): Promise<Trip> {
    const trip = await this.getTripById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ValidationError(TRIP_TEXT.error.forbidden_update);
    }

    if (trip.status === "delivered") {
      throw new ValidationError(TRIP_TEXT.error.cannot_update_delivered);
    }

    if (trip.status === "cancelled") {
      throw new ValidationError(TRIP_TEXT.error.cannot_update_cancelled);
    }

    const nextStatus = data.status ?? trip.status;

    this.validateStatusTransition(trip.status, nextStatus);

    const nextDeparture =
      data.departure_at !== undefined ? data.departure_at : trip.departure_at;

    const nextArrival =
      data.expected_arrival_at !== undefined
        ? data.expected_arrival_at
        : trip.expected_arrival_at;

    if (
      nextDeparture &&
      nextArrival &&
      new Date(nextArrival) < new Date(nextDeparture)
    ) {
      throw new ValidationError(TRIP_TEXT.error.invalid_time_window);
    }

    if (nextStatus === "cancelled") {
      if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_CANCEL)) {
        throw new ValidationError(TRIP_TEXT.error.forbidden_cancel);
      }
    }

    const rows = (await sql`
      UPDATE trips
      SET
        status = ${nextStatus},
        departure_at = ${nextDeparture},
        expected_arrival_at = ${nextArrival},
        distance_km = COALESCE(
          ${data.distance_km ?? null},
          distance_km
        ),
        cost = COALESCE(
          ${data.cost ?? null},
          cost
        ),
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE id = ${id}
      RETURNING
        id,
        vehicle_id,
        origin_store_id,
        status,
        departure_at,
        expected_arrival_at,
        distance_km,
        cost,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as TripRow[];

    if (!rows.length) {
      throw new NotFoundError(TRIP_TEXT.error.empty_trip);
    }

    return rows[0];
  }

  private static validateStatusTransition(
    currentStatus: TripStatus,
    nextStatus: TripStatus,
  ): void {
    const transitions: Record<TripStatus, TripStatus[]> = {
      planned: ["ready", "cancelled"],
      ready: ["in_transit", "cancelled"],
      in_transit: ["delivered"],
      delivered: [],
      cancelled: [],
    };

    if (
      currentStatus === nextStatus ||
      transitions[currentStatus].includes(nextStatus)
    ) {
      return;
    }

    throw new ValidationError(TRIP_TEXT.error.invalid_status_transition);
  }
}
