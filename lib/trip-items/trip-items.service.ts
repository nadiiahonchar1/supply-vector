import { sql } from "@/db";

import type { CurrentUser } from "@/features/auth/types";
import type {
  CreateTripItemInput,
  TripItem,
  UpdateTripItemInput,
} from "@/features/trip-items/types";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";

import { TRIP_ITEM_TEXT } from "@/features/trip-items/constants/trip-item-text";

type TripItemRow = TripItem;

export class TripItemsService {
  static async getTripItems(currentUser: CurrentUser): Promise<TripItem[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        transfer_request_id,
        pickup_stop_id,
        dropoff_stop_id,
        quantity,
        created_at
      FROM trip_items
      ORDER BY created_at DESC
    `) as TripItemRow[];

    return rows;
  }

  static async getTripItemById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<TripItem> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        transfer_request_id,
        pickup_stop_id,
        dropoff_stop_id,
        quantity,
        created_at
      FROM trip_items
      WHERE id = ${id}
      LIMIT 1
    `) as TripItemRow[];

    if (!rows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.empty_trip_item);
    }

    return rows[0];
  }

  static async createTripItem(
    data: CreateTripItemInput,
    currentUser: CurrentUser,
  ): Promise<TripItem> {
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
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    const trip = tripRows[0];

    if (trip.status === "delivered" || trip.status === "cancelled") {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    const requestRows = await sql`
    SELECT
      id,
      source_store_id,
      destination_store_id,
      quantity,
      status
    FROM transfer_requests
    WHERE id = ${data.transfer_request_id}
    LIMIT 1
  `;

    if (!requestRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.transfer_request_not_found);
    }

    const transferRequest = requestRows[0];

    if (transferRequest.status !== "approved") {
      throw new ValidationError(
        TRIP_ITEM_TEXT.error.transfer_request_not_available,
      );
    }

    if (data.quantity > transferRequest.quantity) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.quantity_exceeds_request);
    }

    let pickupSequence: number | null = null;

    if (data.pickup_stop_id) {
      const pickupRows = await sql`
      SELECT
        id,
        store_id,
        sequence
      FROM trip_stops
      WHERE id = ${data.pickup_stop_id}
        AND trip_id = ${data.trip_id}
      LIMIT 1
    `;

      if (!pickupRows.length) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }

      if (pickupRows[0].store_id !== transferRequest.source_store_id) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }

      pickupSequence = Number(pickupRows[0].sequence);
    }

    const dropoffRows = await sql`
    SELECT
      id,
      store_id,
      sequence
    FROM trip_stops
    WHERE id = ${data.dropoff_stop_id}
      AND trip_id = ${data.trip_id}
    LIMIT 1
  `;

    if (!dropoffRows.length) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }

    if (dropoffRows[0].store_id !== transferRequest.destination_store_id) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }

    const dropoffSequence = Number(dropoffRows[0].sequence);

    if (pickupSequence !== null && pickupSequence >= dropoffSequence) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_stop_order);
    }

    const rows = (await sql`
    WITH request_lock AS MATERIALIZED (
      SELECT pg_advisory_xact_lock(
        hashtextextended(
          ${data.transfer_request_id}::text,
          0
        )
      )
    ),
    current_assignment AS (
      SELECT
        COALESCE(SUM(ti.quantity), 0) AS assigned
      FROM trip_items ti
      CROSS JOIN request_lock
      WHERE ti.transfer_request_id =
        ${data.transfer_request_id}
    ),
    valid AS (
      SELECT 1
      FROM current_assignment ca
      JOIN transfer_requests tr
        ON tr.id = ${data.transfer_request_id}
      WHERE ca.assigned + ${data.quantity} <= tr.quantity
    )
    INSERT INTO trip_items (
      trip_id,
      transfer_request_id,
      pickup_stop_id,
      dropoff_stop_id,
      quantity,
      created_at
    )
    SELECT
      ${data.trip_id},
      ${data.transfer_request_id},
      ${data.pickup_stop_id ?? null},
      ${data.dropoff_stop_id},
      ${data.quantity},
      NOW()
    FROM valid
    RETURNING
      id,
      trip_id,
      transfer_request_id,
      pickup_stop_id,
      dropoff_stop_id,
      quantity,
      created_at
  `) as TripItemRow[];

    if (!rows.length) {
      throw new ValidationError(
        TRIP_ITEM_TEXT.error.quantity_exceeds_remaining,
      );
    }

    return rows[0];
  }

  static async updateTripItem(
    id: string,
    data: UpdateTripItemInput,
    currentUser: CurrentUser,
  ): Promise<TripItem> {
    const tripItem = await this.getTripItemById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
    SELECT
      id,
      status
    FROM trips
    WHERE id = ${tripItem.trip_id}
    LIMIT 1
  `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    if (
      tripRows[0].status === "delivered" ||
      tripRows[0].status === "cancelled"
    ) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    const requestRows = await sql`
    SELECT
      source_store_id,
      destination_store_id,
      quantity
    FROM transfer_requests
    WHERE id = ${tripItem.transfer_request_id}
    LIMIT 1
  `;

    if (!requestRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.transfer_request_not_found);
    }

    const transferRequest = requestRows[0];

    const nextQuantity = data.quantity ?? tripItem.quantity;

    if (nextQuantity <= 0) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_quantity);
    }

    let pickupSequence: number | null = null;

    const nextPickup =
      data.pickup_stop_id !== undefined
        ? data.pickup_stop_id
        : tripItem.pickup_stop_id;

    const nextDropoff = data.dropoff_stop_id ?? tripItem.dropoff_stop_id;

    if (nextPickup) {
      const pickupRows = await sql`
      SELECT
        id,
        store_id,
        sequence
      FROM trip_stops
      WHERE id = ${nextPickup}
        AND trip_id = ${tripItem.trip_id}
      LIMIT 1
    `;

      if (!pickupRows.length) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }

      if (pickupRows[0].store_id !== transferRequest.source_store_id) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }

      pickupSequence = Number(pickupRows[0].sequence);
    }

    const dropoffRows = await sql`
    SELECT
      id,
      store_id,
      sequence
    FROM trip_stops
    WHERE id = ${nextDropoff}
      AND trip_id = ${tripItem.trip_id}
    LIMIT 1
  `;

    if (!dropoffRows.length) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }

    if (dropoffRows[0].store_id !== transferRequest.destination_store_id) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }

    const dropoffSequence = Number(dropoffRows[0].sequence);

    if (pickupSequence !== null && pickupSequence >= dropoffSequence) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_stop_order);
    }

    const rows = (await sql`
    WITH request_lock AS MATERIALIZED (
      SELECT pg_advisory_xact_lock(
        hashtextextended(
          ${tripItem.transfer_request_id}::text,
          0
        )
      )
    ),
    other_assignment AS (
      SELECT
        COALESCE(SUM(ti.quantity), 0) AS assigned
      FROM trip_items ti
      CROSS JOIN request_lock
      WHERE ti.transfer_request_id =
        ${tripItem.transfer_request_id}
        AND ti.id <> ${id}
    ),
    valid AS (
      SELECT 1
      FROM other_assignment oa
      JOIN transfer_requests tr
        ON tr.id = ${tripItem.transfer_request_id}
      WHERE oa.assigned + ${nextQuantity} <= tr.quantity
    )
    UPDATE trip_items
    SET
      quantity = ${nextQuantity},
      pickup_stop_id = ${nextPickup},
      dropoff_stop_id = ${nextDropoff}
    WHERE id = ${id}
      AND EXISTS (
        SELECT 1
        FROM valid
      )
    RETURNING
      id,
      trip_id,
      transfer_request_id,
      pickup_stop_id,
      dropoff_stop_id,
      quantity,
      created_at
  `) as TripItemRow[];

    if (!rows.length) {
      throw new ValidationError(
        TRIP_ITEM_TEXT.error.quantity_exceeds_remaining,
      );
    }

    return rows[0];
  }

  static async deleteTripItem(
    id: string,
    currentUser: CurrentUser,
  ): Promise<void> {
    const tripItem = await this.getTripItemById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError();
    }

    const tripRows = await sql`
      SELECT
        status
      FROM trips
      WHERE id = ${tripItem.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    if (
      tripRows[0].status === "delivered" ||
      tripRows[0].status === "cancelled"
    ) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    await sql`
      DELETE FROM trip_items
      WHERE id = ${id}
    `;
  }
}
