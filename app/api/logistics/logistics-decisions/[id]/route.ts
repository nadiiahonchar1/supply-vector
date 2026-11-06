import { NextRequest, NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";
import { LogisticsDecisionsService } from "@/lib/logistics";
import { updateLogisticsDecisionStatusSchema } from "@/features/logistics";
import { AuditService } from "@/lib/audit";
import { validate } from "@/lib/validation";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: NextRequest, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const decision = await LogisticsDecisionsService.getLogisticsDecisionById(
      id,
      currentUser,
    );

    return NextResponse.json(decision);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: NextRequest, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const body = await request.json();

    const input = validate(updateLogisticsDecisionStatusSchema, body);

    const decision = await LogisticsDecisionsService.updateSystemDecisionStatus(
      id,
      input.decision_status,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "logistics_decision",
      entityId: decision.id,
    });

    return NextResponse.json(decision);
  } catch (error) {
    return handleApiError(error);
  }
}