import { sql } from "@/db";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth/types";

import type {
  Shipment,
  ShipmentItem,
  ShipmentStatus,
  CreateShipmentInput,
  UpdateShipmentInput,
} from "@/features/shipments/types";

import { SHIPMENT_TEXT } from "@/features/shipments/constants/shipment-text";

type TransferRequestRow = {
  id: string;
  source_store_id: string;
  destination_store_id: string;
  product_id: string;
  quantity: number;
  status: string;
  shipment_id: string | null;
};

type ShipmentRow = Shipment;

type ShipmentItemRow = ShipmentItem;

export class ShipmentsService {
  static async getShipments(currentUser: CurrentUser): Promise<Shipment[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_VIEW)) {
      throw new ForbiddenError();
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
      throw new ForbiddenError();
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
      throw new ForbiddenError();
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

    const transferRequests = (await sql`
    SELECT
      id,
      source_store_id,
      destination_store_id,
      product_id,
      quantity,
      status,
      shipment_id
    FROM transfer_requests
    WHERE id = ${data.transfer_request_id}
    LIMIT 1
  `) as TransferRequestRow[];

    if (!transferRequests.length) {
      throw new NotFoundError(SHIPMENT_TEXT.error.transfer_request_not_found);
    }

    const transferRequest = transferRequests[0];

    if (transferRequest.shipment_id) {
      throw new ValidationError(SHIPMENT_TEXT.error.shipment_already_exists);
    }

    if (
      transferRequest.status !== "pending" &&
      transferRequest.status !== "approved"
    ) {
      throw new ValidationError(SHIPMENT_TEXT.error.invalid_transfer_request);
    }

    const shipmentId = crypto.randomUUID();
    const shipmentNumber = `SHP-${Date.now()}`;

    const rows = (await sql`
    WITH reserved_inventory AS (
      UPDATE inventory
      SET
        reserved_quantity =
          reserved_quantity + ${transferRequest.quantity}
      WHERE store_id = ${transferRequest.source_store_id}
        AND product_id = ${transferRequest.product_id}
        AND quantity - reserved_quantity >= ${transferRequest.quantity}
      RETURNING store_id, product_id
    ),

    created_shipment AS (
      INSERT INTO shipments (
        id,
        shipment_number,
        source_store_id,
        destination_store_id,
        status,
        created_by,
        updated_by
      )
      SELECT
        ${shipmentId},
        ${shipmentNumber},
        ${transferRequest.source_store_id},
        ${transferRequest.destination_store_id},
        'pending',
        ${currentUser.id},
        ${currentUser.id}
      FROM reserved_inventory
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
    ),

    created_item AS (
      INSERT INTO shipment_items (
        shipment_id,
        product_id,
        quantity
      )
      SELECT
        ${shipmentId},
        ${transferRequest.product_id},
        ${transferRequest.quantity}
      FROM created_shipment
    )

    UPDATE transfer_requests
    SET
      shipment_id = ${shipmentId},
      updated_by = ${currentUser.id},
      updated_at = NOW()
    WHERE id = ${transferRequest.id}
      AND EXISTS (
        SELECT 1
        FROM created_shipment
      )

    RETURNING
      ${shipmentId} AS id,
      ${shipmentNumber} AS shipment_number,
      ${transferRequest.source_store_id} AS source_store_id,
      ${transferRequest.destination_store_id} AS destination_store_id,
      'pending' AS status,
      ${currentUser.id} AS created_by,
      ${currentUser.id} AS updated_by,
      NOW() AS created_at,
      NOW() AS updated_at,
      NULL::timestamp AS completed_at
  `) as ShipmentRow[];

    if (!rows.length) {
      throw new ValidationError(SHIPMENT_TEXT.error.insufficient_inventory);
    }

    return rows[0];
  }

  static async updateShipment(
    id: string,
    data: UpdateShipmentInput,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    if (!hasPermission(currentUser.role, PERMISSIONS.SHIPMENT_UPDATE)) {
      throw new ForbiddenError(SHIPMENT_TEXT.error.forbidden_update);
    }

    const shipment = await this.getShipmentById(id, currentUser);

    if (!this.isValidStatusTransition(shipment.status, data.status)) {
      throw new ValidationError(SHIPMENT_TEXT.error.invalid_status_transition);
    }

    const completedAt = data.status === "completed" ? new Date() : null;

    const rows = (await sql`
      UPDATE shipments
      SET
        status = ${data.status},
        updated_by = ${currentUser.id},
        updated_at = NOW(),
        completed_at = ${completedAt}
      WHERE id = ${id}
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
      throw new NotFoundError(SHIPMENT_TEXT.error.empty_shipment);
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
