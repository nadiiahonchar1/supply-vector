import { sql } from "@/db";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import type { CurrentUser } from "@/features/auth/types";
import type {
  CreateTransferRequestInput,
  TransferRequest,
  TransferRequestStatus,
  UpdateTransferRequestInput,
} from "@/features/transfer-requests/types";
import { TRANSFER_REQUEST_TEXT } from "@/features/transfer-requests/constants/transfer-request-text";
import { ValidationError, NotFoundError } from "@/lib/errors";

type TransferRequestRow = TransferRequest;

export class TransferRequestsService {
  static async getTransferRequests(
    currentUser: CurrentUser,
  ): Promise<TransferRequest[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_VIEW)) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        source_store_id,
        destination_store_id,
        product_id,
        quantity,
        priority,
        status,
        earliest_delivery,
        latest_delivery,
        shipment_id,
        created_by,
        updated_by,
        created_at,
        updated_at,
        cancelled_at
      FROM transfer_requests
      ORDER BY created_at DESC
    `) as TransferRequestRow[];

    return rows;
  }

  static async getTransferRequestById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_VIEW)) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        source_store_id,
        destination_store_id,
        product_id,
        quantity,
        priority,
        status,
        earliest_delivery,
        latest_delivery,
        shipment_id,
        created_by,
        updated_by,
        created_at,
        updated_at,
        cancelled_at
      FROM transfer_requests
      WHERE id = ${id}
      LIMIT 1
    `) as TransferRequestRow[];

    if (!rows.length) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.empty_transfer_request,
      );
    }

    return rows[0];
  }

  static async createTransferRequest(
    data: CreateTransferRequestInput,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_CREATE)) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.forbidden_create);
    }

    if (data.source_store_id === data.destination_store_id) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.same_stores);
    }

    if (
      data.earliest_delivery &&
      data.latest_delivery &&
      new Date(data.latest_delivery) < new Date(data.earliest_delivery)
    ) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.invalid_delivery_window,
      );
    }

    const storeRows = await sql`
      SELECT id
      FROM stores
      WHERE id IN (
        ${data.source_store_id},
        ${data.destination_store_id}
      )
        AND is_active = TRUE
    `;

    if (storeRows.length !== 2) {
      const sourceExists = storeRows.some(
        (store) => store.id === data.source_store_id,
      );

      throw new NotFoundError(
        sourceExists
          ? TRANSFER_REQUEST_TEXT.error.destination_store_not_found
          : TRANSFER_REQUEST_TEXT.error.source_store_not_found,
      );
    }

    const productRows = await sql`
      SELECT id
      FROM products
      WHERE id = ${data.product_id}
        AND is_active = TRUE
      LIMIT 1
    `;

    if (!productRows.length) {
      throw new NotFoundError(TRANSFER_REQUEST_TEXT.error.product_not_found);
    }

    const rows = (await sql`
      INSERT INTO transfer_requests (
        source_store_id,
        destination_store_id,
        product_id,
        quantity,
        priority,
        status,
        earliest_delivery,
        latest_delivery,
        created_by,
        updated_by,
        created_at,
        updated_at
      )
      VALUES (
        ${data.source_store_id},
        ${data.destination_store_id},
        ${data.product_id},
        ${data.quantity},
        ${data.priority},
        'pending',
        ${data.earliest_delivery ?? null},
        ${data.latest_delivery ?? null},
        ${currentUser.id},
        ${currentUser.id},
        NOW(),
        NOW()
      )
      RETURNING
        id,
        source_store_id,
        destination_store_id,
        product_id,
        quantity,
        priority,
        status,
        earliest_delivery,
        latest_delivery,
        shipment_id,
        created_by,
        updated_by,
        created_at,
        updated_at,
        cancelled_at
    `) as TransferRequestRow[];

    return rows[0];
  }

  static async updateTransferRequest(
    id: string,
    data: UpdateTransferRequestInput,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    const transferRequest = await this.getTransferRequestById(id, currentUser);

    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_UPDATE)) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.forbidden_update);
    }

    if (transferRequest.status === "fulfilled") {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.cannot_update_fulfilled,
      );
    }

    if (transferRequest.status === "cancelled") {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.cannot_update_cancelled,
      );
    }

    if (
      data.earliest_delivery &&
      data.latest_delivery &&
      new Date(data.latest_delivery) < new Date(data.earliest_delivery)
    ) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.invalid_delivery_window,
      );
    }

    const nextStatus = data.status ?? transferRequest.status;

    this.validateStatusTransition(transferRequest.status, nextStatus);

    if (nextStatus === "cancelled") {
      if (
        !hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_CANCEL)
      ) {
        throw new ValidationError(TRANSFER_REQUEST_TEXT.error.forbidden_cancel);
      }
    }

    const rows = (await sql`
      UPDATE transfer_requests
      SET
        priority = COALESCE(
          ${data.priority ?? null},
          priority
        ),
        status = ${nextStatus},
        earliest_delivery = COALESCE(
          ${data.earliest_delivery ?? null},
          earliest_delivery
        ),
        latest_delivery = COALESCE(
          ${data.latest_delivery ?? null},
          latest_delivery
        ),
        updated_by = ${currentUser.id},
        updated_at = NOW(),
        cancelled_at = CASE
          WHEN ${nextStatus} = 'cancelled'
            THEN NOW()
          ELSE cancelled_at
        END
      WHERE id = ${id}
      RETURNING
        id,
        source_store_id,
        destination_store_id,
        product_id,
        quantity,
        priority,
        status,
        earliest_delivery,
        latest_delivery,
        shipment_id,
        created_by,
        updated_by,
        created_at,
        updated_at,
        cancelled_at
    `) as TransferRequestRow[];

    if (!rows.length) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.empty_transfer_request,
      );
    }

    return rows[0];
  }

  private static validateStatusTransition(
    currentStatus: TransferRequestStatus,
    nextStatus: TransferRequestStatus,
  ): void {
    const transitions: Record<TransferRequestStatus, TransferRequestStatus[]> =
      {
        pending: ["approved", "cancelled"],
        approved: ["cancelled"],
        fulfilled: [],
        cancelled: [],
      };

    if (
      currentStatus === nextStatus ||
      transitions[currentStatus].includes(nextStatus)
    ) {
      return;
    }

    throw new ValidationError(
      TRANSFER_REQUEST_TEXT.error.invalid_status_transition,
    );
  }
}
