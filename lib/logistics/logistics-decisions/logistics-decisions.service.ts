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
  LogisticsDecisionDetails,
} from "@/features/logistics";

type LogisticsDecisionRow = LogisticsDecision;
type LogisticsDecisionDetailsRow = LogisticsDecisionDetails;

export class LogisticsDecisionsService {
  static async getLogisticsDecisions(
    currentUser: CurrentUser,
  ): Promise<LogisticsDecisionDetails[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
    SELECT
      ld.id,
      ld.transfer_request_id,
      ld.shipment_id,
      ld.trip_id,
      ld.decision_type,
      ld.total_cost,
      ld.cost_breakdown,
      ld.reasoning,
      ld.decision_source,
      ld.decision_status,
      ld.decided_by,
      ld.created_at,

      CASE
        WHEN s.id IS NOT NULL THEN jsonb_build_object(
          'id', s.id,
          'shipment_number', s.shipment_number,
          'status', s.status,
          'source_store', jsonb_build_object(
            'id', source_store.id,
            'name', source_store.name,
            'city', source_store.city
          ),
          'destination_store', jsonb_build_object(
            'id', destination_store.id,
            'name', destination_store.name,
            'city', destination_store.city
          ),
          'product', CASE
            WHEN p.id IS NOT NULL THEN jsonb_build_object(
              'id', p.id,
              'name', p.name,
              'sku', p.sku
            )
            ELSE NULL
          END,
          'quantity', si.quantity
        )
        ELSE NULL
      END AS shipment,

      CASE
        WHEN tr.id IS NOT NULL THEN jsonb_build_object(
          'id', tr.id,
          'status', tr.status,
          'priority', tr.priority,
          'quantity', tr.quantity,
          'earliest_delivery', tr.earliest_delivery,
          'latest_delivery', tr.latest_delivery
        )
        ELSE NULL
      END AS transfer_request,

      CASE
        WHEN t.id IS NOT NULL THEN jsonb_build_object(
          'id', t.id,
          'status', t.status,
          'distance_km', t.distance_km,
          'cost', t.cost,
          'vehicle', jsonb_build_object(
            'id', v.id,
            'name', v.name,
            'type', v.type
          )
        )
        ELSE NULL
      END AS trip

    FROM logistics_decisions ld

    LEFT JOIN shipments s
      ON s.id = ld.shipment_id

    LEFT JOIN shipment_items si
      ON si.shipment_id = s.id

    LEFT JOIN products p
      ON p.id = si.product_id

    LEFT JOIN stores source_store
      ON source_store.id = s.source_store_id

    LEFT JOIN stores destination_store
      ON destination_store.id = s.destination_store_id

    LEFT JOIN transfer_requests tr
      ON tr.id = ld.transfer_request_id

    LEFT JOIN trips t
      ON t.id = ld.trip_id

    LEFT JOIN vehicles v
      ON v.id = t.vehicle_id

    ORDER BY ld.created_at DESC
  `) as LogisticsDecisionDetailsRow[];

    return rows;
  }

  static async getLogisticsDecisionById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecisionDetails> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_view);
    }

    const rows = (await sql`
    SELECT
      ld.id,
      ld.transfer_request_id,
      ld.shipment_id,
      ld.trip_id,
      ld.decision_type,
      ld.total_cost,
      ld.cost_breakdown,
      ld.reasoning,
      ld.decision_source,
      ld.decision_status,
      ld.decided_by,
      ld.created_at,

      CASE
        WHEN s.id IS NOT NULL THEN jsonb_build_object(
          'id', s.id,
          'shipment_number', s.shipment_number,
          'status', s.status,
          'source_store', jsonb_build_object(
            'id', source_store.id,
            'name', source_store.name,
            'city', source_store.city
          ),
          'destination_store', jsonb_build_object(
            'id', destination_store.id,
            'name', destination_store.name,
            'city', destination_store.city
          ),
          'product', CASE
            WHEN p.id IS NOT NULL THEN jsonb_build_object(
              'id', p.id,
              'name', p.name,
              'sku', p.sku
            )
            ELSE NULL
          END,
          'quantity', si.quantity
        )
        ELSE NULL
      END AS shipment,

      CASE
        WHEN tr.id IS NOT NULL THEN jsonb_build_object(
          'id', tr.id,
          'status', tr.status,
          'priority', tr.priority,
          'quantity', tr.quantity,
          'earliest_delivery', tr.earliest_delivery,
          'latest_delivery', tr.latest_delivery
        )
        ELSE NULL
      END AS transfer_request,

      CASE
        WHEN t.id IS NOT NULL THEN jsonb_build_object(
          'id', t.id,
          'status', t.status,
          'distance_km', t.distance_km,
          'cost', t.cost,
          'vehicle', jsonb_build_object(
            'id', v.id,
            'name', v.name,
            'type', v.type
          )
        )
        ELSE NULL
      END AS trip

    FROM logistics_decisions ld

    LEFT JOIN shipments s
      ON s.id = ld.shipment_id

    LEFT JOIN shipment_items si
      ON si.shipment_id = s.id

    LEFT JOIN products p
      ON p.id = si.product_id

    LEFT JOIN stores source_store
      ON source_store.id = s.source_store_id

    LEFT JOIN stores destination_store
      ON destination_store.id = s.destination_store_id

    LEFT JOIN transfer_requests tr
      ON tr.id = ld.transfer_request_id

    LEFT JOIN trips t
      ON t.id = ld.trip_id

    LEFT JOIN vehicles v
      ON v.id = t.vehicle_id

    WHERE ld.id = ${id}
    LIMIT 1
  `) as LogisticsDecisionDetailsRow[];

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

    const transactionResults = await sql.transaction([
      sql`
      SELECT pg_advisory_xact_lock(
        hashtext(${transferRequestId})
      )
    `,

      sql`
      UPDATE logistics_decisions AS current_decision
      SET decision_status = 'superseded'
      WHERE current_decision.transfer_request_id = ${transferRequestId}
        AND current_decision.decision_source = 'system'
        AND current_decision.decision_status = 'pending'
        AND NOT EXISTS (
          SELECT 1
          FROM jsonb_to_recordset(
            ${recommendationsJson}::JSONB
          ) AS recommendation(
            shipment_id UUID,
            trip_id UUID,
            decision_type TEXT,
            total_cost NUMERIC,
            cost_breakdown JSONB,
            reasoning TEXT
          )
          WHERE recommendation.shipment_id =
            current_decision.shipment_id
            AND recommendation.trip_id IS NOT DISTINCT FROM
              current_decision.trip_id
            AND recommendation.decision_type =
              current_decision.decision_type
            AND recommendation.total_cost IS NOT DISTINCT FROM
              current_decision.total_cost
            AND recommendation.cost_breakdown =
              current_decision.cost_breakdown
            AND recommendation.reasoning =
              current_decision.reasoning
        )
    `,

      sql`
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
      FROM jsonb_to_recordset(
        ${recommendationsJson}::JSONB
      ) AS recommendation(
        shipment_id UUID,
        trip_id UUID,
        decision_type TEXT,
        total_cost NUMERIC,
        cost_breakdown JSONB,
        reasoning TEXT
      )
      WHERE NOT EXISTS (
        SELECT 1
        FROM logistics_decisions AS existing
        WHERE existing.transfer_request_id = ${transferRequestId}
          AND existing.shipment_id = recommendation.shipment_id
          AND existing.decision_source = 'system'
          AND existing.decision_status = 'pending'
      )
      ON CONFLICT (transfer_request_id, shipment_id)
      WHERE decision_source = 'system'
        AND decision_status = 'pending'
      DO NOTHING
    `,

      sql`
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
      WHERE transfer_request_id = ${transferRequestId}
        AND decision_source = 'system'
        AND decision_status = 'pending'
      ORDER BY created_at DESC
    `,
    ]);

    const decisions = transactionResults[3] as LogisticsDecisionRow[];

    return decisions;
  }

  static async updateSystemDecisionStatus(
    id: string,
    status: Extract<LogisticsDecisionStatus, "accepted" | "rejected">,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_update);
    }

    const existingRows = await sql`
      SELECT
        id,
        decision_source,
        decision_status,
        decision_type
      FROM logistics_decisions
      WHERE id = ${id}
      LIMIT 1
    `;

    if (existingRows.length === 0) {
      throw new NotFoundError(LOGISTICS_DECISION_TEXT.error.empty_decision);
    }

    const existingDecision = existingRows[0];

    if (
      existingDecision.decision_source !== "system" ||
      existingDecision.decision_status !== "pending"
    ) {
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.decision_status_not_available,
      );
    }

    if (
      status === "accepted" &&
      existingDecision.decision_type === "create_new_trip" &&
      !hasPermission(currentUser.role, PERMISSIONS.TRIP_CREATE)
    ) {
      throw new ForbiddenError(LOGISTICS_DECISION_TEXT.error.forbidden_create);
    }

    if (status === "accepted") {
      try {
        const rows = (await sql`
          SELECT *
          FROM accept_logistics_decision(
            ${id}::UUID,
            ${currentUser.id}::UUID
          )
        `) as LogisticsDecisionRow[];

        if (rows.length === 0) {
          throw new ValidationError(
            LOGISTICS_DECISION_TEXT.error.decision_status_not_available,
          );
        }

        return rows[0];
      } catch (error) {
        if (
          error instanceof NotFoundError ||
          error instanceof ValidationError
        ) {
          throw error;
        }

        const message = error instanceof Error ? error.message : "";

        if (message.includes("LOGISTICS_DECISION_NOT_FOUND")) {
          throw new NotFoundError(LOGISTICS_DECISION_TEXT.error.empty_decision);
        }

        if (message.includes("LOGISTICS_DECISION_NOT_AVAILABLE")) {
          throw new ValidationError(
            LOGISTICS_DECISION_TEXT.error.decision_status_not_available,
          );
        }

        const validationErrors: Record<string, string> = {
          LOGISTICS_DECISION_INVALID:
            LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,

          LOGISTICS_SHIPMENT_NOT_AVAILABLE:
            LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,

          LOGISTICS_REQUEST_NOT_AVAILABLE:
            LOGISTICS_DECISION_TEXT.error.request_not_approved,

          LOGISTICS_SHIPMENT_ALREADY_ASSIGNED:
            LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,

          LOGISTICS_TRIP_REQUIRED: LOGISTICS_DECISION_TEXT.error.trip_required,

          LOGISTICS_TRIP_NOT_AVAILABLE:
            LOGISTICS_DECISION_TEXT.error.trip_not_available,

          LOGISTICS_TRIP_STOPS_NOT_AVAILABLE:
            LOGISTICS_DECISION_TEXT.error.trip_not_available,

          LOGISTICS_TRIP_NOT_ALLOWED:
            LOGISTICS_DECISION_TEXT.error.trip_not_allowed,

          LOGISTICS_VEHICLE_REQUIRED:
            LOGISTICS_DECISION_TEXT.error.trip_required,

          LOGISTICS_VEHICLE_NOT_AVAILABLE:
            LOGISTICS_DECISION_TEXT.error.trip_not_available,

          LOGISTICS_VEHICLE_ALREADY_ASSIGNED:
            LOGISTICS_DECISION_TEXT.error.trip_not_available,

          LOGISTICS_TRIP_ITEM_NOT_CREATED:
            LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,

          LOGISTICS_DECISION_TYPE_INVALID:
            LOGISTICS_DECISION_TEXT.error.transfer_request_not_available,

          TRIP_CAPACITY_EXCEEDED:
            LOGISTICS_DECISION_TEXT.error.trip_not_available,
        };

        const matchedError = Object.entries(validationErrors).find(([code]) =>
          message.includes(code),
        );

        if (matchedError) {
          throw new ValidationError(matchedError[1]);
        }

        throw error;
      }
    }

    const rows = (await sql`
      UPDATE logistics_decisions
      SET
        decision_status = 'rejected',
        decided_by = ${currentUser.id}
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
      throw new ValidationError(
        LOGISTICS_DECISION_TEXT.error.decision_status_not_available,
      );
    }

    return rows[0];
  }
}
