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

  private static async completeShipment(
    shipment: Shipment,
    currentUser: CurrentUser,
  ): Promise<Shipment> {
    const rows = (await sql`
    WITH shipment_data AS (
      SELECT
        si.id AS shipment_item_id,
        si.product_id,
        si.quantity
      FROM shipment_items si
      WHERE si.shipment_id = ${shipment.id}
    ),

    source_inventory AS (
      UPDATE inventory i
      SET
        quantity = i.quantity - sd.quantity,
        reserved_quantity =
          i.reserved_quantity - sd.quantity
      FROM shipment_data sd
      WHERE i.store_id = ${shipment.source_store_id}
        AND i.product_id = sd.product_id
        AND i.quantity >= sd.quantity
        AND i.reserved_quantity >= sd.quantity
      RETURNING
        i.product_id,
        i.quantity + sd.quantity AS quantity_before,
        i.quantity AS quantity_after,
        sd.quantity,
        sd.shipment_item_id
    ),

    valid_source AS (
      SELECT 1
      WHERE
        (SELECT COUNT(*) FROM shipment_data) > 0
        AND
        (
          SELECT COUNT(*)
          FROM source_inventory
        ) = (
          SELECT COUNT(*)
          FROM shipment_data
        )
    ),

    transfer_out_movements AS (
      INSERT INTO inventory_movements (
        store_id,
        product_id,
        quantity_change,
        quantity_before,
        quantity_after,
        movement_type,
        shipment_id,
        shipment_item_id,
        created_by
      )
      SELECT
        ${shipment.source_store_id},
        si.product_id,
        -si.quantity,
        si.quantity_before,
        si.quantity_after,
        'transfer_out',
        ${shipment.id},
        si.shipment_item_id,
        ${currentUser.id}
      FROM source_inventory si
      CROSS JOIN valid_source
      RETURNING id
    ),

    destination_before AS (
      SELECT
        i.product_id,
        i.quantity AS quantity_before
      FROM inventory i
      JOIN shipment_data sd
        ON sd.product_id = i.product_id
      CROSS JOIN valid_source
      WHERE i.store_id = ${shipment.destination_store_id}
    ),

    destination_inventory AS (
      INSERT INTO inventory (
        store_id,
        product_id,
        quantity,
        reserved_quantity
      )
      SELECT
        ${shipment.destination_store_id},
        sd.product_id,
        sd.quantity,
        0
      FROM shipment_data sd
      CROSS JOIN valid_source
      ON CONFLICT (store_id, product_id)
      DO UPDATE
      SET
        quantity =
          inventory.quantity + EXCLUDED.quantity
      RETURNING
        product_id,
        quantity
    ),

    transfer_in_movements AS (
      INSERT INTO inventory_movements (
        store_id,
        product_id,
        quantity_change,
        quantity_before,
        quantity_after,
        movement_type,
        shipment_id,
        shipment_item_id,
        created_by
      )
      SELECT
        ${shipment.destination_store_id},
        di.product_id,
        sd.quantity,
        COALESCE(db.quantity_before, 0),
        di.quantity,
        'transfer_in',
        ${shipment.id},
        sd.shipment_item_id,
        ${currentUser.id}
      FROM destination_inventory di
      JOIN shipment_data sd
        ON sd.product_id = di.product_id
      LEFT JOIN destination_before db
        ON db.product_id = di.product_id
      CROSS JOIN valid_source
      RETURNING id
    ),

    updated_transfer_request AS (
      UPDATE transfer_requests
      SET
        status = 'fulfilled',
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE shipment_id = ${shipment.id}
        AND status IN ('pending', 'approved')
      RETURNING id
    )

    UPDATE shipments
    SET
      status = 'completed',
      completed_at = NOW(),
      updated_by = ${currentUser.id},
      updated_at = NOW()
    WHERE id = ${shipment.id}
      AND EXISTS (
        SELECT 1
        FROM updated_transfer_request
      )
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
    WITH shipment_data AS (
      SELECT
        si.id AS shipment_item_id,
        si.product_id,
        si.quantity
      FROM shipment_items si
      WHERE si.shipment_id = ${shipment.id}
    ),

    released_inventory AS (
      UPDATE inventory i
      SET
        reserved_quantity =
          i.reserved_quantity - sd.quantity
      FROM shipment_data sd
      WHERE i.store_id = ${shipment.source_store_id}
        AND i.product_id = sd.product_id
        AND i.reserved_quantity >= sd.quantity
      RETURNING
        i.product_id,
        i.reserved_quantity + sd.quantity AS reserved_before,
        i.reserved_quantity AS reserved_after,
        sd.quantity,
        sd.shipment_item_id
    ),

    valid_inventory AS (
      SELECT 1
      WHERE
        (SELECT COUNT(*) FROM shipment_data) > 0
        AND
        (
          SELECT COUNT(*)
          FROM released_inventory
        ) = (
          SELECT COUNT(*)
          FROM shipment_data
        )
    )

    UPDATE shipments
    SET
      status = 'cancelled',
      updated_by = ${currentUser.id},
      updated_at = NOW()
    WHERE id = ${shipment.id}
      AND EXISTS (
        SELECT 1
        FROM valid_inventory
      )
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
