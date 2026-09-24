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

    const existingRows = await sql`
      SELECT
        COALESCE(SUM(quantity), 0) AS assigned_quantity
      FROM trip_items
      WHERE transfer_request_id = ${data.transfer_request_id}
    `;

    const assignedQuantity = Number(existingRows[0]?.assigned_quantity ?? 0);

    const remainingQuantity =
      Number(transferRequest.quantity) - assignedQuantity;

    if (data.quantity > remainingQuantity) {
      throw new ValidationError(
        TRIP_ITEM_TEXT.error.quantity_exceeds_remaining,
      );
    }

    if (data.pickup_stop_id) {
      const pickupRows = await sql`
        SELECT
          id,
          store_id
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
    }

    const dropoffRows = await sql`
      SELECT
        id,
        store_id
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

    const rows = (await sql`
      INSERT INTO trip_items (
        trip_id,
        transfer_request_id,
        pickup_stop_id,
        dropoff_stop_id,
        quantity,
        created_at
      )
      VALUES (
        ${data.trip_id},
        ${data.transfer_request_id},
        ${data.pickup_stop_id ?? null},
        ${data.dropoff_stop_id},
        ${data.quantity},
        NOW()
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

    const otherItemsRows = await sql`
      SELECT
        COALESCE(SUM(quantity), 0) AS assigned_quantity
      FROM trip_items
      WHERE transfer_request_id = ${tripItem.transfer_request_id}
        AND id <> ${id}
    `;

    const assignedElsewhere = Number(otherItemsRows[0]?.assigned_quantity ?? 0);

    if (nextQuantity > Number(transferRequest.quantity) - assignedElsewhere) {
      throw new ValidationError(
        TRIP_ITEM_TEXT.error.quantity_exceeds_remaining,
      );
    }

    const nextPickup =
      data.pickup_stop_id !== undefined
        ? data.pickup_stop_id
        : tripItem.pickup_stop_id;

    const nextDropoff = data.dropoff_stop_id ?? tripItem.dropoff_stop_id;

    if (nextPickup) {
      const pickupRows = await sql`
        SELECT
          id,
          store_id
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
    }

    const dropoffRows = await sql`
      SELECT
        id,
        store_id
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

    const rows = (await sql`
      UPDATE trip_items
      SET
        quantity = ${nextQuantity},
        pickup_stop_id = ${nextPickup},
        dropoff_stop_id = ${nextDropoff}
      WHERE id = ${id}
      RETURNING
        id,
        trip_id,
        transfer_request_id,
        pickup_stop_id,
        dropoff_stop_id,
        quantity,
        created_at
    `) as TripItemRow[];

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
