import { sql } from "@/db";

import type { CurrentUser } from "@/features/auth/types";
import type {
  CreateTripStopInput,
  TripStop,
  UpdateTripStopInput,
} from "@/features/trip-stops/types";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";

import { TRIP_STOP_TEXT } from "@/features/trip-stops/constants/trip-stop-text";

type TripStopRow = TripStop;

export class TripStopsService {
  static async getTripStops(currentUser: CurrentUser): Promise<TripStop[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        store_id,
        sequence,
        expected_arrival_at,
        actual_arrival_at
      FROM trip_stops
      ORDER BY trip_id, sequence
    `) as TripStopRow[];

    return rows;
  }

  static async getTripStopById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<TripStop> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        store_id,
        sequence,
        expected_arrival_at,
        actual_arrival_at
      FROM trip_stops
      WHERE id = ${id}
      LIMIT 1
    `) as TripStopRow[];

    if (!rows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.empty_trip_stop);
    }

    return rows[0];
  }

  static async createTripStop(
    data: CreateTripStopInput,
    currentUser: CurrentUser,
  ): Promise<TripStop> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
      SELECT
        id,
        status
      FROM trips
      WHERE id = ${data.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.trip_not_found);
    }

    if (
      tripRows[0].status === "delivered" ||
      tripRows[0].status === "cancelled"
    ) {
      throw new ValidationError(TRIP_STOP_TEXT.error.trip_not_modifiable);
    }

    const storeRows = await sql`
      SELECT
        id
      FROM stores
      WHERE id = ${data.store_id}
        AND is_active = TRUE
      LIMIT 1
    `;

    if (!storeRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.store_not_found);
    }

    const existingRows = await sql`
      SELECT id
      FROM trip_stops
      WHERE trip_id = ${data.trip_id}
        AND sequence = ${data.sequence}
      LIMIT 1
    `;

    if (existingRows.length) {
      throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
    }

    const rows = (await sql`
      INSERT INTO trip_stops (
        trip_id,
        store_id,
        sequence,
        expected_arrival_at
      )
      VALUES (
        ${data.trip_id},
        ${data.store_id},
        ${data.sequence},
        ${data.expected_arrival_at ?? null}
      )
      RETURNING
        id,
        trip_id,
        store_id,
        sequence,
        expected_arrival_at,
        actual_arrival_at
    `) as TripStopRow[];

    return rows[0];
  }

  static async updateTripStop(
    id: string,
    data: UpdateTripStopInput,
    currentUser: CurrentUser,
  ): Promise<TripStop> {
    const tripStop = await this.getTripStopById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
      SELECT
        id,
        status
      FROM trips
      WHERE id = ${tripStop.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.trip_not_found);
    }

    if (
      tripRows[0].status === "delivered" ||
      tripRows[0].status === "cancelled"
    ) {
      throw new ValidationError(TRIP_STOP_TEXT.error.trip_not_modifiable);
    }

    const nextSequence = data.sequence ?? tripStop.sequence;

    if (nextSequence <= 0) {
      throw new ValidationError(TRIP_STOP_TEXT.error.invalid_sequence);
    }

    if (nextSequence !== tripStop.sequence) {
      const existingRows = await sql`
        SELECT id
        FROM trip_stops
        WHERE trip_id = ${tripStop.trip_id}
          AND sequence = ${nextSequence}
          AND id <> ${id}
        LIMIT 1
      `;

      if (existingRows.length) {
        throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
      }
    }

    const rows = (await sql`
      UPDATE trip_stops
      SET
        sequence = ${nextSequence},
        expected_arrival_at =
          ${
            data.expected_arrival_at !== undefined
              ? data.expected_arrival_at
              : tripStop.expected_arrival_at
          },
        actual_arrival_at =
          ${
            data.actual_arrival_at !== undefined
              ? data.actual_arrival_at
              : tripStop.actual_arrival_at
          }
      WHERE id = ${id}
      RETURNING
        id,
        trip_id,
        store_id,
        sequence,
        expected_arrival_at,
        actual_arrival_at
    `) as TripStopRow[];

    return rows[0];
  }

  static async deleteTripStop(
    id: string,
    currentUser: CurrentUser,
  ): Promise<void> {
    const tripStop = await this.getTripStopById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
      SELECT
        status
      FROM trips
      WHERE id = ${tripStop.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.trip_not_found);
    }

    if (
      tripRows[0].status === "delivered" ||
      tripRows[0].status === "cancelled"
    ) {
      throw new ValidationError(TRIP_STOP_TEXT.error.trip_not_modifiable);
    }

    if (tripStop.sequence === 1) {
      throw new ValidationError(TRIP_STOP_TEXT.error.cannot_delete_origin);
    }

    await sql`
      DELETE FROM trip_stops
      WHERE id = ${id}
    `;
  }
}
