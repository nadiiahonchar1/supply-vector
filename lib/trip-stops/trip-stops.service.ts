import { sql } from "@/db";
import type { CurrentUser } from "@/features/auth";
import { PERMISSIONS, hasPermission } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";
import { TRIP_STOP_TEXT } from "@/features/trip-stops/constants/trip-stop-text";
import type {
  CreateTripStopInput,
  TripStop,
  UpdateTripStopInput,
} from "@/features/trip-stops/types";

type TripStopRow = TripStop;

export class TripStopsService {
  static async getTripStops(
    tripId: string,
    currentUser: CurrentUser,
  ): Promise<TripStop[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
      SELECT id
      FROM trips
      WHERE id = ${tripId}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.trip_not_found);
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
      WHERE trip_id = ${tripId}
      ORDER BY sequence ASC
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

    const existingStopRows = await sql`
      SELECT id
      FROM trip_stops
      WHERE trip_id = ${data.trip_id}
        AND sequence = ${data.sequence}
      LIMIT 1
    `;

    if (existingStopRows.length) {
      throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
    }

    await this.validateArrivalTime(
      data.trip_id,
      data.sequence,
      data.expected_arrival_at ?? null,
    );

    try {
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
    } catch (error) {
      if (this.isUniqueViolation(error)) {
        throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
      }

      throw error;
    }
  }

  static async updateTripStop(
    id: string,
    data: UpdateTripStopInput,
    currentUser: CurrentUser,
  ): Promise<TripStop> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripStopRows = (await sql`
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

    if (!tripStopRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.empty_trip_stop);
    }

    const tripStop = tripStopRows[0];

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

    const nextExpectedArrival =
      data.expected_arrival_at !== undefined
        ? data.expected_arrival_at
        : tripStop.expected_arrival_at;

    if (nextSequence <= 0) {
      throw new ValidationError(TRIP_STOP_TEXT.error.invalid_sequence);
    }

    const existingStopRows = await sql`
      SELECT id
      FROM trip_stops
      WHERE trip_id = ${tripStop.trip_id}
        AND sequence = ${nextSequence}
        AND id <> ${id}
      LIMIT 1
    `;

    if (existingStopRows.length) {
      throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
    }

    await this.validateArrivalTime(
      tripStop.trip_id,
      nextSequence,
      nextExpectedArrival,
      id,
    );

    try {
      const rows = (await sql`
        UPDATE trip_stops
        SET
          sequence = ${nextSequence},
          expected_arrival_at = ${nextExpectedArrival},
          actual_arrival_at = ${data.actual_arrival_at ?? tripStop.actual_arrival_at}
        WHERE id = ${id}
        RETURNING
          id,
          trip_id,
          store_id,
          sequence,
          expected_arrival_at,
          actual_arrival_at
      `) as TripStopRow[];

      if (!rows.length) {
        throw new NotFoundError(TRIP_STOP_TEXT.error.empty_trip_stop);
      }

      return rows[0];
    } catch (error) {
      if (this.isUniqueViolation(error)) {
        throw new ValidationError(TRIP_STOP_TEXT.error.sequence_already_exists);
      }

      throw error;
    }
  }

  static async deleteTripStop(
    id: string,
    currentUser: CurrentUser,
  ): Promise<void> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripStopRows = (await sql`
      SELECT
        id,
        trip_id,
        sequence
      FROM trip_stops
      WHERE id = ${id}
      LIMIT 1
    `) as Array<{
      id: string;
      trip_id: string;
      sequence: number;
    }>;

    if (!tripStopRows.length) {
      throw new NotFoundError(TRIP_STOP_TEXT.error.empty_trip_stop);
    }

    const tripStop = tripStopRows[0];

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

    if (tripStop.sequence === 1) {
      throw new ValidationError(TRIP_STOP_TEXT.error.cannot_delete_first_stop);
    }

    const referencingItemsRows = await sql`
      SELECT id
      FROM trip_items
      WHERE pickup_stop_id = ${id}
         OR dropoff_stop_id = ${id}
      LIMIT 1
    `;

    if (referencingItemsRows.length) {
      throw new ValidationError(TRIP_STOP_TEXT.error.stop_has_cargo);
    }

    try {
      const result = await sql`
         DELETE FROM trip_stops
         WHERE id = ${id}
         RETURNING id
      `;

      if (result.length === 0) {
        throw new NotFoundError(TRIP_STOP_TEXT.error.empty_trip_stop);
      }
    } catch (error) {
      if (this.isForeignKeyViolation(error)) {
        throw new ValidationError(TRIP_STOP_TEXT.error.stop_has_cargo);
      }

      throw error;
    }
  }

  private static async validateArrivalTime(
    tripId: string,
    sequence: number,
    expectedArrivalAt: string | null,
    currentStopId?: string,
  ): Promise<void> {
    if (!expectedArrivalAt) {
      return;
    }

    const previousRows = await sql`
      SELECT expected_arrival_at
      FROM trip_stops
      WHERE trip_id = ${tripId}
        AND sequence < ${sequence}
        ${currentStopId ? sql`AND id <> ${currentStopId}` : sql``}
      ORDER BY sequence DESC
      LIMIT 1
    `;

    const nextRows = await sql`
      SELECT expected_arrival_at
      FROM trip_stops
      WHERE trip_id = ${tripId}
        AND sequence > ${sequence}
        ${currentStopId ? sql`AND id <> ${currentStopId}` : sql``}
      ORDER BY sequence ASC
      LIMIT 1
    `;

    const previousArrival = previousRows[0]?.expected_arrival_at ?? null;

    const nextArrival = nextRows[0]?.expected_arrival_at ?? null;

    const expectedTimestamp = new Date(expectedArrivalAt).getTime();

    if (
      previousArrival &&
      expectedTimestamp < new Date(previousArrival).getTime()
    ) {
      throw new ValidationError(TRIP_STOP_TEXT.error.invalid_arrival_time);
    }

    if (nextArrival && expectedTimestamp > new Date(nextArrival).getTime()) {
      throw new ValidationError(TRIP_STOP_TEXT.error.invalid_arrival_time);
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

  private static isForeignKeyViolation(error: unknown): boolean {
    return (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "23503"
    );
  }
}
