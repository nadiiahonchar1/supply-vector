import { sql } from "@/db";
import { TRIP_ITEM_TEXT } from "@/features/trips";
import { hasPermission, PERMISSIONS } from "@/lib/auth";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth";
import type {
  CreateTripItemInput,
  TripItem,
  UpdateTripItemInput,
} from "@/features/trips";

type TripItemRow = TripItem;

export class TripItemsService {
  static async getTripItems(currentUser: CurrentUser): Promise<TripItemRow[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(TRIP_ITEM_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        shipment_id,
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
  ): Promise<TripItemRow> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(TRIP_ITEM_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        trip_id,
        shipment_id,
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
  ): Promise<TripItemRow> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(TRIP_ITEM_TEXT.error.forbidden_create);
    }

    const tripRows = await sql`
      SELECT id, status
      FROM trips
      WHERE id = ${data.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    const trip = tripRows[0];

    if (["delivered", "cancelled"].includes(trip.status)) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    const shipmentRows = await sql`
      SELECT
        s.id,
        s.transfer_request_id,
        s.source_store_id,
        s.destination_store_id,
        s.status AS shipment_status,
        tr.status AS request_status
      FROM shipments s
      JOIN transfer_requests tr
        ON tr.id = s.transfer_request_id
      WHERE s.id = ${data.shipment_id}
      LIMIT 1
    `;

    if (!shipmentRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.shipment_not_found);
    }

    const shipment = shipmentRows[0];

    if (
      shipment.shipment_status !== "pending" ||
      !["pending", "approved"].includes(shipment.request_status)
    ) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.shipment_not_available);
    }

    if (data.pickup_stop_id) {
      const pickupRows = await sql`
        SELECT id, store_id, sequence
        FROM trip_stops
        WHERE id = ${data.pickup_stop_id}
          AND trip_id = ${data.trip_id}
        LIMIT 1
      `;

      if (
        !pickupRows.length ||
        pickupRows[0].store_id !== shipment.source_store_id
      ) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }
    }

    const dropoffRows = await sql`
      SELECT id, store_id, sequence
      FROM trip_stops
      WHERE id = ${data.dropoff_stop_id}
        AND trip_id = ${data.trip_id}
      LIMIT 1
    `;

    if (
      !dropoffRows.length ||
      dropoffRows[0].store_id !== shipment.destination_store_id
    ) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }
   
    if (data.pickup_stop_id) {
      const pickupRows = await sql`
        SELECT sequence
        FROM trip_stops
        WHERE id = ${data.pickup_stop_id}
          AND trip_id = ${data.trip_id}
        LIMIT 1
      `;

      if (
        pickupRows.length &&
        pickupRows[0].sequence >= dropoffRows[0].sequence
      ) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_stop_order);
      }
    }

    const rows = (await sql`
      SELECT *
      FROM create_trip_item(
        ${data.trip_id}::uuid,
        ${data.shipment_id}::uuid,
        ${data.pickup_stop_id ?? null}::uuid,
        ${data.dropoff_stop_id}::uuid,
        ${data.quantity}
      )
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
  ): Promise<TripItemRow> {
    const tripItem = await this.getTripItemById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(TRIP_ITEM_TEXT.error.forbidden_update);
    }

    if (!tripItem.shipment_id) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.legacy_item_not_editable);
    }

    const tripRows = await sql`
      SELECT id, status
      FROM trips
      WHERE id = ${tripItem.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    if (["delivered", "cancelled"].includes(tripRows[0].status)) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    const transferRequestRows = await sql`
      SELECT
        source_store_id,
        destination_store_id,
        quantity
      FROM transfer_requests
      WHERE id = ${tripItem.transfer_request_id}
      LIMIT 1
    `;

    if (!transferRequestRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.transfer_request_not_found);
    }

    const transferRequest = transferRequestRows[0];

    const nextQuantity = data.quantity ?? tripItem.quantity;
    const nextPickupStopId =
      data.pickup_stop_id === undefined
        ? tripItem.pickup_stop_id
        : data.pickup_stop_id;
    const nextDropoffStopId = data.dropoff_stop_id ?? tripItem.dropoff_stop_id;

    if (nextQuantity <= 0) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_quantity);
    }

    if (nextPickupStopId) {
      const pickupRows = await sql`
        SELECT id, store_id, sequence
        FROM trip_stops
        WHERE id = ${nextPickupStopId}
          AND trip_id = ${tripItem.trip_id}
        LIMIT 1
      `;

      if (
        !pickupRows.length ||
        pickupRows[0].store_id !== transferRequest.source_store_id
      ) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.pickup_store_mismatch);
      }
    }

    const dropoffRows = await sql`
      SELECT id, store_id, sequence
      FROM trip_stops
      WHERE id = ${nextDropoffStopId}
        AND trip_id = ${tripItem.trip_id}
      LIMIT 1
    `;

    if (
      !dropoffRows.length ||
      dropoffRows[0].store_id !== transferRequest.destination_store_id
    ) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.dropoff_store_mismatch);
    }

    if (nextPickupStopId) {
      const pickupRows = await sql`
        SELECT sequence
        FROM trip_stops
        WHERE id = ${nextPickupStopId}
          AND trip_id = ${tripItem.trip_id}
        LIMIT 1
      `;

      if (
        pickupRows.length &&
        pickupRows[0].sequence >= dropoffRows[0].sequence
      ) {
        throw new ValidationError(TRIP_ITEM_TEXT.error.invalid_stop_order);
      }
    }

    const rows = (await sql`
      SELECT *
      FROM update_trip_item(
        ${id}::uuid,
        ${nextPickupStopId}::uuid,
        ${nextDropoffStopId}::uuid,
        ${nextQuantity}
      )
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
  ): Promise<{ success: boolean }> {
    const tripItem = await this.getTripItemById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(TRIP_ITEM_TEXT.error.forbidden_delete);
    }

    const tripRows = await sql`
      SELECT id, status
      FROM trips
      WHERE id = ${tripItem.trip_id}
      LIMIT 1
    `;

    if (!tripRows.length) {
      throw new NotFoundError(TRIP_ITEM_TEXT.error.trip_not_found);
    }

    if (["delivered", "cancelled"].includes(tripRows[0].status)) {
      throw new ValidationError(TRIP_ITEM_TEXT.error.trip_not_modifiable);
    }

    await sql`
      DELETE FROM trip_items
      WHERE id = ${id}
    `;

    return { success: true };
  }
}
