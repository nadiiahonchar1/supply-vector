import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { validate } from "@/lib/validation";
import { createTransferRequestSchema } from "@/features/transfer-requests/validation/transfer-request.schema";
import { TransferRequestsService } from "@/lib/transfer-requests/transfer-requests.service";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const transferRequests =
      await TransferRequestsService.getTransferRequests(currentUser);

    return NextResponse.json(transferRequests);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const currentUser = await requireUser();

    const body: unknown = await request.json();

    const data = validate(createTransferRequestSchema, body);

    const transferRequest = await TransferRequestsService.createTransferRequest(
      data,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "transfer_request:create",
      entity: "transfer_request",
      entityId: transferRequest.id,
    });

    return NextResponse.json(transferRequest, {
      status: 201,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
