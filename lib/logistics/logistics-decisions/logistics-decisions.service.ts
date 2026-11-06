import { sql } from "@/db";
import { LOGISTICS_DECISION_TEXT } from "@/features/logistics";
import { PERMISSIONS, hasPermission } from "@/lib/auth";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth";
import type {
  CreateLogisticsDecisionInput,
  LogisticsDecision,
  LogisticsDecisionRecommendation,
  LogisticsDecisionStatus,
} from "@/features/logistics";

type LogisticsDecisionRow = LogisticsDecision;

export class LogisticsDecisionsService {
  static async getLogisticsDecisions(
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        transfer_request_id,
        shipment_id,
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
        decision_status,
        decided_by,
        created_at
      FROM logistics_decisions
      ORDER BY created_at DESC
    `) as LogisticsDecisionRow[];

    return rows;
  }

  static async getLogisticsDecisionById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
      SELECT
        id,
        transfer_request_id,
        shipment_id,
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
        decision_status,
        decided_by,
        created_at
      FROM logistics_decisions
      WHERE id = ${id}
      LIMIT 1
    `) as LogisticsDecisionRow[];

    if (!rows.length) {
      throw new NotFoundError(LOGISTICS_DECISION_TEXT.error.empty_decision);
    }

    return rows[0];
  }

  static async createLogisticsDecision(
    data: CreateLogisticsDecisionInput,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_update);
    }

    const transferRequestRows = await sql`
      SELECT
        id,
        status
      FROM transfer_requests
      WHERE id = ${data.transfer_request_id}
      LIMIT 1
    `;

    if (!transferRequestRows.length) {
      throw new NotFoundError(
        LOGISTICS_DECISION_TEXT.error.transfer_request_not_found,
      );
    }

    if (transferRequestRows[0].status !== "approved") {
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,
      );
    }

    if (data.trip_id) {
      const tripRows = await sql`
        SELECT
          id,
          status
        FROM trips
        WHERE id = ${data.trip_id}
        LIMIT 1
      `;

      if (!tripRows.length) {
        throw new NotFoundError(LOGISTICS_DECISION_TEXT.error.trip_not_found);
      }

      if (
        tripRows[0].status === "delivered" ||
        tripRows[0].status === "cancelled"
      ) {
        throw new ValidationError(
          LOGISTICS_DECISION_TEXT.error.trip_not_available,
        );
      }
    }

    if (data.decision_type === "add_to_existing_trip" && !data.trip_id) {
      throw new ValidationError(LOGISTICS_DECISION_TEXT.error.trip_required);
    }

    if (data.decision_type === "create_new_trip" && data.trip_id) {
      throw new ValidationError(LOGISTICS_DECISION_TEXT.error.trip_not_allowed);
    }

    if (data.decision_type === "defer" && data.trip_id) {
      throw new ValidationError(LOGISTICS_DECISION_TEXT.error.trip_not_allowed);
    }

    if (
      data.total_cost !== undefined &&
      data.total_cost !== null &&
      data.total_cost < 0
    ) {
      throw new ValidationError(LOGISTICS_DECISION_TEXT.error.invalid_cost);
    }

    if (!data.reasoning.trim()) {
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.invalid_reasoning,
      );
    }

    const decisionSource = data.decision_source ?? "manual";

    const decidedBy = decisionSource === "manual" ? currentUser.id : null;

    const rows = (await sql`
      INSERT INTO logistics_decisions (
        transfer_request_id,
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
        decided_by,
        created_at
      )
      VALUES (
        ${data.transfer_request_id},
        ${data.trip_id ?? null},
        ${data.decision_type},
        ${data.total_cost ?? null},
        ${data.cost_breakdown ?? {}},
        ${data.reasoning.trim()},
        ${decisionSource},
        ${decidedBy},
        NOW()
      )
      RETURNING
        id,
        transfer_request_id,
        shipment_id,
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
        decision_status,
        decided_by,
        created_at
    `) as LogisticsDecisionRow[];

    return rows[0];
  }
  static async createSystemLogisticsDecisions(
    transferRequestId: string,
    recommendations: LogisticsDecisionRecommendation[],
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_update);
    }

    if (recommendations.length === 0) {
      return [];
    }

    const request = await sql`
    SELECT id, status
    FROM transfer_requests
    WHERE id = ${transferRequestId}
    LIMIT 1
  `;

    if (request.length === 0) {
      throw new NotFoundError(
        LOGISTICS_DECISION_TEXT.error.transfer_request_not_found,
      );
    }

    if (request[0].status !== "approved") {
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.request_not_approved,
      );
    }

    const invalidRecommendation = recommendations.some(
      (recommendation) =>
        recommendation.transfer_request_id !== transferRequestId ||
        !recommendation.shipment_id,
    );

    if (invalidRecommendation) {
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,
      );
    }

    const recommendationsJson = JSON.stringify(
      recommendations.map((recommendation) => ({
        shipment_id: recommendation.shipment_id,
        trip_id: recommendation.trip_id,
        decision_type: recommendation.decision_type,
        total_cost: recommendation.total_cost,
        cost_breakdown: recommendation.cost_breakdown,
        reasoning: recommendation.reasoning,
      })),
    );

    const decisions = await sql`
    INSERT INTO logistics_decisions (
      transfer_request_id,
      shipment_id,
      trip_id,
      decision_type,
      total_cost,
      cost_breakdown,
      reasoning,
      decision_source,
      decision_status,
      decided_by
    )
    SELECT
      ${transferRequestId},
      recommendation.shipment_id,
      recommendation.trip_id,
      recommendation.decision_type,
      recommendation.total_cost,
      recommendation.cost_breakdown,
      recommendation.reasoning,
      'system',
      'pending',
      NULL
    FROM jsonb_to_recordset(${recommendationsJson}::JSONB) AS recommendation(
      shipment_id UUID,
      trip_id UUID,
      decision_type TEXT,
      total_cost NUMERIC,
      cost_breakdown JSONB,
      reasoning TEXT
    )
    RETURNING
      id,
      transfer_request_id,
      shipment_id,
      trip_id,
      decision_type,
      total_cost,
      cost_breakdown,
      reasoning,
      decision_source,
      decision_status,
      decided_by,
      created_at
  `;

    return decisions as LogisticsDecision[];
  }

  static async updateSystemDecisionStatus(
    id: string,
    status: Extract<LogisticsDecisionStatus, "accepted" | "rejected">,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_update);
    }

    const rows = (await sql`
    UPDATE logistics_decisions
    SET decision_status = ${status}
    WHERE id = ${id}
      AND decision_source = 'system'
      AND decision_status = 'pending'
    RETURNING
      id,
      transfer_request_id,
      shipment_id,
      trip_id,
      decision_type,
      total_cost,
      cost_breakdown,
      reasoning,
      decision_source,
      decision_status,
      decided_by,
      created_at
  `) as LogisticsDecisionRow[];

    if (rows.length === 0) {
      const existingRows = await sql`
      SELECT id
      FROM logistics_decisions
      WHERE id = ${id}
      LIMIT 1
    `;

      if (existingRows.length === 0) {
        throw new NotFoundError(LOGISTICS_DECISION_TEXT.error.empty_decision);
      }

      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.decision_status_not_available,
      );
    }

    return rows[0];
  }
}
