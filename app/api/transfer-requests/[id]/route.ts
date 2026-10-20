import { NextResponse } from "next/server";

import { updateTransferRequestSchema } from "@/features/transfer-requests";
import { requireUser } from "@/lib/auth/server";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { TransferRequestsService } from "@/lib/transfer-requests";

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

    const action =
      data.status === "cancelled"
        ? "transfer_request:cancel"
        : "transfer_request:update";

    await AuditService.log({
      userId: currentUser.id,
      action,
      entity: "transfer_request",
      entityId: transferRequest.id,
      meta: {
        status: transferRequest.status,
      },
    });

    return NextResponse.json(transferRequest);
  } catch (error) {
    return handleApiError(error);
  }
}
