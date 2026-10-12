import { sql } from "@/db";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";
import type { CurrentUser } from "@/features/auth";
import type {
  CreateTransferRequestInput,
  TransferRequest,
  UpdateTransferRequestInput,
} from "@/features/transfer-requests/types";
import { TRANSFER_REQUEST_TEXT } from "@/features/transfer-requests/constants/transfer-request-text";

export const TransferRequestsService = {
  async getTransferRequests(
    currentUser: CurrentUser,
  ): Promise<TransferRequest[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_VIEW)) {
      throw new ForbiddenError(TRANSFER_REQUEST_TEXT.error.forbidden_view);
    }

    const requests = await sql`
      SELECT *
      FROM transfer_requests
      ORDER BY created_at DESC
    `;

    return requests as TransferRequest[];
  },

  async getTransferRequestById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_VIEW)) {
      throw new ForbiddenError(TRANSFER_REQUEST_TEXT.error.forbidden_view);
    }

    const [request] = await sql`
      SELECT *
      FROM transfer_requests
      WHERE id = ${id}
      LIMIT 1
    `;

    if (!request) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.empty_transfer_request,
      );
    }

    return request as TransferRequest;
  },

  async createTransferRequest(
    data: CreateTransferRequestInput,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRANSFER_REQUEST_CREATE)) {
      throw new ForbiddenError(TRANSFER_REQUEST_TEXT.error.forbidden_create);
    }

    if (data.source_store_id === data.destination_store_id) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.same_stores);
    }

    this.validateDeliveryWindow(data.earliest_delivery, data.latest_delivery);

    const [sourceStore] = await sql`
      SELECT id, is_active, is_storage_node
      FROM stores
      WHERE id = ${data.source_store_id}
      LIMIT 1
    `;

    if (!sourceStore) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.source_store_not_found,
      );
    }

    if (!sourceStore.is_active) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.source_store_inactive,
      );
    }

    if (!sourceStore.is_storage_node) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.source_store_not_storage_node,
      );
    }

    const [destinationStore] = await sql`
      SELECT id, is_active
      FROM stores
      WHERE id = ${data.destination_store_id}
      LIMIT 1
    `;

    if (!destinationStore) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.destination_store_not_found,
      );
    }

    if (!destinationStore.is_active) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.destination_store_inactive,
      );
    }

    const [product] = await sql`
      SELECT id, is_active
      FROM products
      WHERE id = ${data.product_id}
      LIMIT 1
    `;

    if (!product) {
      throw new NotFoundError(TRANSFER_REQUEST_TEXT.error.product_not_found);
    }

    if (!product.is_active) {
      throw new ValidationError(TRANSFER_REQUEST_TEXT.error.product_inactive);
    }

    const [request] = await sql`
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
        updated_by
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
        ${currentUser.id}
      )
      RETURNING *
    `;

    if (!request) {
      throw new Error("Не вдалося створити заявку на переміщення");
    }

    return request as TransferRequest;
  },

  async updateTransferRequest(
    id: string,
    data: UpdateTransferRequestInput,
    currentUser: CurrentUser,
  ): Promise<TransferRequest> {
    const existingRequest = await this.getTransferRequestById(id, currentUser);
    if (
      existingRequest.status === "fulfilled" ||
      existingRequest.status === "cancelled"
    ) {
      throw new ValidationError(
        existingRequest.status === "fulfilled"
          ? TRANSFER_REQUEST_TEXT.error.cannot_update_fulfilled
          : TRANSFER_REQUEST_TEXT.error.cannot_update_cancelled,
      );
    }

    const isCancelling = data.status === "cancelled";

    const requiredPermission = isCancelling
      ? PERMISSIONS.TRANSFER_REQUEST_CANCEL
      : PERMISSIONS.TRANSFER_REQUEST_UPDATE;

    const forbiddenMessage = isCancelling
      ? TRANSFER_REQUEST_TEXT.error.forbidden_cancel
      : TRANSFER_REQUEST_TEXT.error.forbidden_update;

    if (!hasPermission(currentUser.role, requiredPermission)) {
      throw new ForbiddenError(forbiddenMessage);
    }

    const nextStatus = data.status ?? existingRequest.status;

    if (nextStatus !== existingRequest.status) {
      this.validateStatusTransition(existingRequest.status, nextStatus);
    }

    const earliestDelivery =
      data.earliest_delivery !== undefined
        ? data.earliest_delivery
        : existingRequest.earliest_delivery;

    const latestDelivery =
      data.latest_delivery !== undefined
        ? data.latest_delivery
        : existingRequest.latest_delivery;

    this.validateDeliveryWindow(earliestDelivery, latestDelivery);

    const [updatedRequest] = await sql`
      UPDATE transfer_requests
      SET
        status = ${nextStatus},
        priority = ${data.priority ?? existingRequest.priority},
        earliest_delivery = ${earliestDelivery},
        latest_delivery = ${latestDelivery},
        updated_by = ${currentUser.id},
        updated_at = NOW(),
        cancelled_at = CASE
          WHEN ${nextStatus} = 'cancelled' THEN COALESCE(cancelled_at, NOW())
          ELSE cancelled_at
        END
      WHERE id = ${id}
      RETURNING *
    `;

    if (!updatedRequest) {
      throw new NotFoundError(
        TRANSFER_REQUEST_TEXT.error.empty_transfer_request,
      );
    }

    return updatedRequest as TransferRequest;
  },

  validateDeliveryWindow(
    earliestDelivery: string | null | undefined,
    latestDelivery: string | null | undefined,
  ): void {
    if (
      earliestDelivery &&
      latestDelivery &&
      new Date(earliestDelivery).getTime() > new Date(latestDelivery).getTime()
    ) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.invalid_delivery_window,
      );
    }
  },

  validateStatusTransition(
    currentStatus: TransferRequest["status"],
    nextStatus: TransferRequest["status"],
  ): void {
    const allowedTransitions: Record<
      TransferRequest["status"],
      TransferRequest["status"][]
    > = {
      pending: ["approved", "cancelled"],
      approved: ["cancelled"],
      fulfilled: [],
      cancelled: [],
    };

    if (!allowedTransitions[currentStatus].includes(nextStatus)) {
      throw new ValidationError(
        TRANSFER_REQUEST_TEXT.error.invalid_status_transition,
      );
    }
  },
};
