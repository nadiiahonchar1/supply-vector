import { sql } from "@/db";
import type { CurrentUser } from "@/features/auth";
import { LOGISTICS_DECISION_TEXT } from "@/features/logistics-decisions/constants/logistics-decision-text";
import type {
  CreateLogisticsDecisionInput,
  LogisticsDecision,
} from "@/features/logistics-decisions/types";
import { PERMISSIONS, hasPermission } from "@/lib/auth/permissions";
import { NotFoundError, ValidationError, ForbiddenError } from "@/lib/errors";

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
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
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
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
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
        trip_id,
        decision_type,
        total_cost,
        cost_breakdown,
        reasoning,
        decision_source,
        decided_by,
        created_at
    `) as LogisticsDecisionRow[];

    return rows[0];
  }
}
