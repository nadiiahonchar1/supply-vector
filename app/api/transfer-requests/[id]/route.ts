import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";
import { updateTransferRequestSchema } from "@/features/transfer-requests/validation/transfer-request.schema";
import { TransferRequestsService } from "@/lib/transfer-requests/transfer-requests.service";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const transferRequest =
      await TransferRequestsService.getTransferRequestById(id, currentUser);

    return NextResponse.json(transferRequest);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: Request, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const body: unknown = await request.json();

    const data = validate(updateTransferRequestSchema, body);

    const transferRequest = await TransferRequestsService.updateTransferRequest(
      id,
      data,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "transfer_request:update",
      entity: "transfer_request",
      entityId: transferRequest.id,
    });

    return NextResponse.json(transferRequest);
  } catch (error) {
    return handleApiError(error);
  }
}
