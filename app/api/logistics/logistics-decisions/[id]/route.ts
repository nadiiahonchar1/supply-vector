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

    if (
      decision.decision_status === "accepted" &&
      decision.decision_type === "create_new_trip" &&
      decision.trip_id
    ) {
      await AuditService.log({
        userId: currentUser.id,
        action: "trip:create",
        entity: "trip",
        entityId: decision.trip_id,
        meta: {
          source: "logistics_decision",
          decision_id: decision.id,
          shipment_id: decision.shipment_id,
          transfer_request_id: decision.transfer_request_id,
          decision_type: decision.decision_type,
        },
      });
    } else if (
      decision.decision_status === "accepted" &&
      decision.decision_type === "add_to_existing_trip" &&
      decision.trip_id
    ) {
      await AuditService.log({
        userId: currentUser.id,
        action: "trip:update",
        entity: "trip",
        entityId: decision.trip_id,
        meta: {
          source: "logistics_decision",
          decision_id: decision.id,
          shipment_id: decision.shipment_id,
          transfer_request_id: decision.transfer_request_id,
          decision_type: decision.decision_type,
        },
      });
    } else {
      await AuditService.log({
        userId: currentUser.id,
        action: "trip:update",
        entity: "logistics_decision",
        entityId: decision.id,
        meta: {
          decision_status: decision.decision_status,
          decision_type: decision.decision_type,
          shipment_id: decision.shipment_id,
        },
      });
    }

    return NextResponse.json(decision);
  } catch (error) {
    return handleApiError(error);
  }
}