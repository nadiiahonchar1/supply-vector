import { sql } from "@/db";

import { SHIPMENT_TEXT } from "@/features/shipments";
import { hasPermission, PERMISSIONS } from "@/lib/auth";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth";
import type {
  Shipment,
  ShipmentItem,
  ShipmentStatus,
  CreateShipmentInput,
  UpdateShipmentInput,
} from "@/features/shipments";

type ShipmentRow = Shipment;

type ShipmentItemRow = ShipmentItem;

export class ShipmentsService {
  static async getShipments(currentUser: CurrentUser): Promise<Shipment[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_VIEW)) {
      throw new ForbiddenError(SHIPMENT_TEXT.error.forbidden_view);
    }

    return (await sql`
      SELECT
        id,
        shipment_number,
        source_store_id,
        destination_store_id,
        status,
        created_by,
        updated_by,
        created_at,
        updated_at,
        completed_at
      FROM shipments
      ORDER BY created_at DESC
    `) as ShipmentRow[];
  }

  static async getShipmentById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_VIEW)) {
      throw new ForbiddenError(SHIPMENT_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        shipment_number,
        source_store_id,
        destination_store_id,
        status,
        created_by,
        updated_by,
        created_at,
        updated_at,
        completed_at
      FROM shipments
      WHERE id = ${id}
      LIMIT 1
    `) as ShipmentRow[];

    if (!rows.length) {
      throw new NotFoundError(SHIPMENT_TEXT.error.empty_shipment);
    }

    return rows[0];
  }

  static async getShipmentItems(
    shipmentId: string,
    currentUser: CurrentUser,
  ): Promise<ShipmentItem[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_VIEW)) {
      throw new ForbiddenError(SHIPMENT_TEXT.error.forbidden_view);
    }

    await this.getShipmentById(shipmentId, currentUser);

    return (await sql`
    SELECT
      id,
      shipment_id,
      product_id,
      quantity
    FROM shipment_items
    WHERE shipment_id = ${shipmentId}
  `) as ShipmentItemRow[];
  }

  static async createShipment(
    data: CreateShipmentInput,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_CREATE)) {
      throw new ForbiddenError(SHIPMENT_TEXT.error.forbidden_create);
    }

    const shipmentId = crypto.randomUUID();
    const shipmentNumber = `SHP-${crypto
      .randomUUID()
      .slice(0, 8)
      .toUpperCase()}`;

    const rows = (await sql`
      SELECT *
      FROM create_partial_shipment(
        ${shipmentId},
        ${shipmentNumber},
        ${data.transfer_request_id},
        ${data.quantity},
        ${currentUser.id}
      )
    `) as Shipment[];

    if (rows.length > 0) {
      return rows[0];
    }

    const requests = (await sql`
      SELECT
        tr.id,
        tr.status,
        tr.quantity,
        tr.source_store_id,
        tr.product_id,
        COALESCE(
          (
            SELECT SUM(si.quantity)
            FROM shipments s
            JOIN shipment_items si
              ON si.shipment_id = s.id
            WHERE s.transfer_request_id = tr.id
              AND s.status <> 'cancelled'
          ),
          0
        ) AS allocated_quantity
      FROM transfer_requests tr
      WHERE tr.id = ${data.transfer_request_id}
      LIMIT 1
    `) as {
      id: string;
      status: string;
      quantity: number;
      source_store_id: string;
      product_id: string;
      allocated_quantity: number | string;
    }[];

    if (!requests.length) {
      throw new NotFoundError(SHIPMENT_TEXT.error.transfer_request_not_found);
    }

    const request = requests[0];
    const allocatedQuantity = Number(request.allocated_quantity);

    if (!["pending", "approved"].includes(request.status)) {
      throw new ValidationError(SHIPMENT_TEXT.error.invalid_transfer_request);
    }

    if (allocatedQuantity + data.quantity > request.quantity) {
      throw new ValidationError(SHIPMENT_TEXT.error.quantity_exceeds_remaining);
    }

    const inventoryRows = (await sql`
      SELECT
        quantity - reserved_quantity - min_stock AS available_quantity
      FROM inventory
      WHERE store_id = ${request.source_store_id}
        AND product_id = ${request.product_id}
      LIMIT 1
    `) as { available_quantity: number }[];

    if (
      !inventoryRows.length ||
      Number(inventoryRows[0].available_quantity) < data.quantity
    ) {
      throw new ValidationError(SHIPMENT_TEXT.error.insufficient_inventory);
    }

    throw new ValidationError(SHIPMENT_TEXT.error.failed_shipment
    );
  }

  static async updateShipment(
    id: string,
    data: UpdateShipmentInput,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    const permission =
      data.status === "cancelled"
        ? PERMISSIONS.SHIPMENT_CANCEL
        : PERMISSIONS.SHIPMENT_UPDATE;

    if (!hasPermission(currentUser.role, permission)) {
      throw new ForbiddenError(
        data.status === "cancelled"
          ? SHIPMENT_TEXT.error.forbidden_cancel
          : SHIPMENT_TEXT.error.forbidden_update,
      );
    }

    const shipment = await this.getShipmentById(id, currentUser);

    if (!this.isValidStatusTransition(shipment.status, data.status)) {
      throw new ValidationError(SHIPMENT_TEXT.error.invalid_status_transition);
    }

    if (data.status === "completed") {
      return this.completeShipment(shipment, currentUser);
    }

    if (data.status === "cancelled") {
      return this.cancelShipment(shipment, currentUser);
    }

    const rows = (await sql`
      UPDATE shipments
      SET
        status = ${data.status},
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE id = ${id}
        AND status = ${shipment.status}
      RETURNING
        id,
        shipment_number,
        source_store_id,
        destination_store_id,
        status,
        created_by,
        updated_by,
        created_at,
        updated_at,
        completed_at
    `) as ShipmentRow[];

    if (!rows.length) {
      throw new ValidationError(SHIPMENT_TEXT.error.invalid_status_transition);
    }

    return rows[0];
  }

  private static async completeShipment(
    shipment: Shipment,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    const rows = (await sql`
    SELECT *
    FROM complete_shipment(
      ${shipment.id},
      ${currentUser.id}
    )
  `) as Shipment[];

    if (!rows.length) {
      throw new ValidationError(
        SHIPMENT_TEXT.error.invalid_shipment_completion,
      );
    }

    return rows[0];
  }

  private static async cancelShipment(
    shipment: Shipment,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    const rows = (await sql`
    SELECT *
    FROM cancel_shipment(
      ${shipment.id},
      ${currentUser.id}
    )
  `) as Shipment[];

    if (!rows.length) {
      throw new ValidationError(
        SHIPMENT_TEXT.error.invalid_shipment_cancellation,
      );
    }

    return rows[0];
  }
  private static isValidStatusTransition(
    currentStatus: ShipmentStatus,
    nextStatus: ShipmentStatus,
  ): boolean {
    const transitions: Record<ShipmentStatus, ShipmentStatus[]> = {
      pending: ["in_transit", "cancelled"],
      in_transit: ["completed"],
      completed: [],
      cancelled: [],
    };

    return transitions[currentStatus].includes(nextStatus);
  }
}
