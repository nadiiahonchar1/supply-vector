import { NextRequest, NextResponse } from "next/server";

import { createLogisticsDecisionSchema } from "@/features/logistics-decisions/validation/logistics-decision.schema";
import { AuditService } from "@/lib/audit";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { LogisticsDecisionsService } from "@/lib/logistics-decisions";
import { validate } from "@/lib/validation";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const decisions =
      await LogisticsDecisionsService.getLogisticsDecisions(
        currentUser,
      );

    return NextResponse.json(decisions);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const currentUser = await requireUser();

    const body = await request.json();

    const input = validate(
      createLogisticsDecisionSchema,
      body,
    );

    const decision = await LogisticsDecisionsService.createLogisticsDecision(
      {
        ...input,
        decision_source: "manual",
      },
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "logistics_decision",
      entityId: decision.id,
    });

    return NextResponse.json(
      decision,
      { status: 201 },
    );
  } catch (error) {
    return handleApiError(error);
  }
}

