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
    WITH locked_request AS MATERIALIZED (
      SELECT
        id,
        source_store_id,
        destination_store_id,
        product_id,
        quantity
      FROM transfer_requests
      WHERE id = ${data.transfer_request_id}
        AND shipment_id IS NULL
        AND status IN ('pending', 'approved')
      FOR UPDATE
    ),

    reserved_inventory AS (
      UPDATE inventory i
      SET
        reserved_quantity = i.reserved_quantity + tr.quantity,
        updated_at = NOW()
      FROM locked_request tr
      WHERE i.store_id = tr.source_store_id
        AND i.product_id = tr.product_id
        AND i.quantity - i.reserved_quantity - i.min_stock >= tr.quantity
      RETURNING i.store_id, i.product_id
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
        tr.source_store_id,
        tr.destination_store_id,
        'pending',
        ${currentUser.id},
        ${currentUser.id}
      FROM locked_request tr
      JOIN reserved_inventory ri
        ON ri.store_id = tr.source_store_id
        AND ri.product_id = tr.product_id
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
        cs.id,
        tr.product_id,
        tr.quantity
      FROM created_shipment cs
      JOIN locked_request tr ON TRUE
      RETURNING id
    ),

    updated_transfer_request AS (
      UPDATE transfer_requests tr
      SET
        shipment_id = cs.id,
        updated_by = ${currentUser.id},
        updated_at = NOW()
      FROM created_shipment cs
      WHERE tr.id = ${data.transfer_request_id}
        AND tr.shipment_id IS NULL
        AND tr.status IN ('pending', 'approved')
      RETURNING tr.id
    )

    SELECT cs.*
    FROM created_shipment cs
    JOIN updated_transfer_request utr ON TRUE
    WHERE EXISTS (SELECT 1 FROM created_item)
  `) as Shipment[];

    if (rows.length === 0) {
      const requests = (await sql`
      SELECT id, shipment_id, status
      FROM transfer_requests
      WHERE id = ${data.transfer_request_id}
      LIMIT 1
    `) as {
        id: string;
        shipment_id: string | null;
        status: string;
      }[];

      if (!requests.length) {
        throw new NotFoundError(SHIPMENT_TEXT.error.transfer_request_not_found);
      }

      if (requests[0].shipment_id) {
        throw new ValidationError(SHIPMENT_TEXT.error.shipment_already_exists);
      }

      if (!["pending", "approved"].includes(requests[0].status)) {
        throw new ValidationError(SHIPMENT_TEXT.error.invalid_transfer_request);
      }

      throw new ValidationError(SHIPMENT_TEXT.error.insufficient_inventory);
    }

    return rows[0];
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
    WITH locked_shipment AS MATERIALIZED (
      SELECT
        id,
        source_store_id
      FROM shipments
      WHERE id = ${shipment.id}
        AND status = 'pending'
      FOR UPDATE
    ),

    locked_request AS MATERIALIZED (
      SELECT tr.id, tr.shipment_id
      FROM transfer_requests tr
      JOIN locked_shipment ls
        ON ls.id = tr.shipment_id
      WHERE tr.status IN ('pending', 'approved')
      FOR UPDATE OF tr
    ),

    shipment_data AS MATERIALIZED (
      SELECT
        si.id AS shipment_item_id,
        si.product_id,
        si.quantity
      FROM shipment_items si
      JOIN locked_shipment ls
        ON ls.id = si.shipment_id
    ),

    locked_inventory AS MATERIALIZED (
      SELECT
        i.id,
        i.reserved_quantity,
        sd.quantity AS shipment_quantity
      FROM inventory i
      JOIN shipment_data sd
        ON sd.product_id = i.product_id
      CROSS JOIN locked_shipment ls
      CROSS JOIN locked_request lr
      WHERE i.store_id = ls.source_store_id
        AND i.reserved_quantity >= sd.quantity
      FOR UPDATE OF i
    ),

    valid_inventory AS MATERIALIZED (
      SELECT 1
      WHERE EXISTS (SELECT 1 FROM locked_request)
        AND (SELECT COUNT(*) FROM shipment_data) > 0
        AND (
          SELECT COUNT(*) FROM locked_inventory
        ) = (
          SELECT COUNT(*) FROM shipment_data
        )
    ),

    released_inventory AS (
      UPDATE inventory i
      SET
        reserved_quantity =
          i.reserved_quantity - li.shipment_quantity,
        updated_at = NOW()
      FROM locked_inventory li
      CROSS JOIN valid_inventory vi
      WHERE i.id = li.id
      RETURNING i.id
    ),

    valid_release AS MATERIALIZED (
      SELECT 1
      WHERE (
        SELECT COUNT(*) FROM released_inventory
      ) = (
        SELECT COUNT(*) FROM shipment_data
      )
    ),

    updated_transfer_request AS (
      UPDATE transfer_requests tr
      SET
        status = 'cancelled',
        cancelled_at = NOW(),
        updated_by = ${currentUser.id},
        updated_at = NOW()
      FROM locked_request lr
      CROSS JOIN valid_release
      WHERE tr.id = lr.id
        AND tr.shipment_id = ${shipment.id}
        AND tr.status IN ('pending', 'approved')
      RETURNING tr.id
    ),

    updated_shipment AS (
      UPDATE shipments s
      SET
        status = 'cancelled',
        updated_by = ${currentUser.id},
        updated_at = NOW()
      FROM locked_shipment ls
      CROSS JOIN updated_transfer_request
      WHERE s.id = ls.id
        AND s.status = 'pending'
      RETURNING
        s.id,
        s.shipment_number,
        s.source_store_id,
        s.destination_store_id,
        s.status,
        s.created_by,
        s.updated_by,
        s.created_at,
        s.updated_at,
        s.completed_at
    )

    SELECT *
    FROM updated_shipment
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
