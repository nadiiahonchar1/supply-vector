import { sql } from "@/db";
import { PERMISSIONS, hasPermission } from "@/lib/auth";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";
import { LOGISTICS_DECISION_ENGINE_TEXT } from "@/features/logistics";

import type { CurrentUser } from "@/features/auth";
import type {
  LogisticsDecisionEngineResult,
  LogisticsDecisionRecommendation,
  LogisticsExistingTripCandidate,
  LogisticsNewTripVehicleCandidate,
  LogisticsTripCandidate,
  LogisticsDecision,
} from "@/features/logistics";

type TransferRequestRow = {
  id: string;
  status: string;
  quantity: number;
  source_store_id: string;
  destination_store_id: string;
  product_id: string;
};

type ShipmentCandidateRow = {
  shipment_id: string;
  shipment_number: string;
  shipment_quantity: number;
  assigned_quantity: number;
  remaining_quantity: number;
};

type NewTripVehicleCandidateRow = LogisticsNewTripVehicleCandidate;

export class LogisticsDecisionEngineService {
  static async findExistingTripCandidates(
    transferRequestId: string,
    currentUser: CurrentUser,
  ): Promise<LogisticsTripCandidate[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_VIEW)) {
      throw new ForbiddenError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.forbidden_view,
      );
    }

    const requestRows = (await sql`
      SELECT
        id,
        status,
        quantity,
        source_store_id,
        destination_store_id,
        product_id
      FROM transfer_requests
      WHERE id = ${transferRequestId}
      LIMIT 1
    `) as TransferRequestRow[];

    if (!requestRows.length) {
      throw new NotFoundError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.request_not_found,
      );
    }

    const request = requestRows[0];

    if (request.status !== "approved") {
      throw new ValidationError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.request_not_approved,
      );
    }

    const shipmentRows = (await sql`
      SELECT
        s.id AS shipment_id,
        s.shipment_number,
        COALESCE(SUM(si.quantity), 0)::INTEGER AS shipment_quantity,
        COALESCE((
          SELECT SUM(ti.quantity)
          FROM trip_items ti
          WHERE ti.shipment_id = s.id
        ), 0)::INTEGER AS assigned_quantity,
        (
          COALESCE(SUM(si.quantity), 0)
          - COALESCE((
            SELECT SUM(ti.quantity)
            FROM trip_items ti
            WHERE ti.shipment_id = s.id
          ), 0)
        )::INTEGER AS remaining_quantity
      FROM shipments s
      JOIN shipment_items si
        ON si.shipment_id = s.id
      WHERE s.transfer_request_id = ${transferRequestId}
        AND s.status = 'pending'
      GROUP BY s.id, s.shipment_number
      HAVING
        COALESCE(SUM(si.quantity), 0)
        - COALESCE((
          SELECT SUM(ti.quantity)
          FROM trip_items ti
          WHERE ti.shipment_id = s.id
        ), 0) > 0
      ORDER BY s.created_at ASC
    `) as ShipmentCandidateRow[];

    if (!shipmentRows.length) {
      return [];
    }

    const candidates: LogisticsTripCandidate[] = [];

    for (const shipment of shipmentRows) {
      const tripRows = (await sql`
        SELECT DISTINCT ON (t.id)
          t.id AS trip_id,
          t.vehicle_id,
          v.name AS vehicle_name,
          t.status,
          t.distance_km,
          t.cost,
          pickup.id AS pickup_stop_id,
          pickup.sequence AS pickup_sequence,
          dropoff.id AS dropoff_stop_id,
          dropoff.sequence AS dropoff_sequence
        FROM trips t
        JOIN vehicles v
          ON v.id = t.vehicle_id
        JOIN trip_stops pickup
          ON pickup.trip_id = t.id
          AND pickup.store_id = ${request.source_store_id}
        JOIN trip_stops dropoff
          ON dropoff.trip_id = t.id
          AND dropoff.store_id = ${request.destination_store_id}
          AND pickup.sequence < dropoff.sequence
        WHERE t.status IN ('planned', 'ready')
          AND v.is_active = TRUE
          AND trip_item_fits_capacity(
            t.id,
            ${shipment.shipment_id}::UUID,
            ${shipment.remaining_quantity},
            NULL
          ) = TRUE
        ORDER BY t.id, pickup.sequence, dropoff.sequence
      `) as LogisticsExistingTripCandidate[];

      const vehicleRows = (await sql`
        SELECT
          v.id AS vehicle_id,
          v.name AS vehicle_name,
          v.type AS vehicle_type,
          v.capacity_weight,
          v.capacity_volume,
          v.cost_per_km,
          v.fixed_cost,
          lr.distance_km,
          lr.estimated_duration_minutes,
          ROUND(
            (
              v.fixed_cost
              + lr.distance_km * v.cost_per_km
            )::NUMERIC,
            2
          ) AS estimated_trip_cost,
          v.available_from,
          v.available_to
        FROM vehicles v
        JOIN logistics_routes lr
          ON lr.store_a_id = LEAST(
            ${request.source_store_id}::UUID,
            ${request.destination_store_id}::UUID
          )
          AND lr.store_b_id = GREATEST(
            ${request.source_store_id}::UUID,
            ${request.destination_store_id}::UUID
          )
        JOIN products p
          ON p.id = ${request.product_id}
        WHERE v.is_active = TRUE
          AND lr.is_active = TRUE
          AND v.capacity_weight >=
            ${shipment.remaining_quantity} * p.weight_kg
          AND (
            v.capacity_volume IS NULL
            OR (
              p.volume_m3 IS NOT NULL
              AND v.capacity_volume >=
                ${shipment.remaining_quantity} * p.volume_m3
            )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM trips active_trip
            WHERE active_trip.vehicle_id = v.id
              AND active_trip.status IN ('ready', 'in_transit')
          )
        ORDER BY estimated_trip_cost ASC, v.name ASC
      `) as NewTripVehicleCandidateRow[];

      candidates.push({
        shipment_id: shipment.shipment_id,
        shipment_number: shipment.shipment_number,
        remaining_quantity: Number(shipment.remaining_quantity),
        trips: tripRows,
        new_trip_vehicles: vehicleRows,
      });
    }

    return candidates;
  }

  static async generateRecommendations(
    transferRequestId: string,
    currentUser: CurrentUser,
  ): Promise<LogisticsDecisionEngineResult> {
    const candidates = await this.findExistingTripCandidates(
      transferRequestId,
      currentUser,
    );

    const recommendations: LogisticsDecisionRecommendation[] = [];

    for (const candidate of candidates) {
      if (candidate.trips.length > 0) {
        const trip = candidate.trips[0];

        recommendations.push({
          transfer_request_id: transferRequestId,
          shipment_id: candidate.shipment_id,
          shipment_number: candidate.shipment_number,
          decision_type: "add_to_existing_trip",
          trip_id: trip.trip_id,
          total_cost: null,
          cost_breakdown: {
            estimated_incremental_cost: null,
            existing_trip_cost: trip.cost,
          },
          reasoning: LOGISTICS_DECISION_ENGINE_TEXT.success.available,
        });

        continue;
      }

      if (candidate.new_trip_vehicles.length > 0) {
        const vehicle = candidate.new_trip_vehicles.reduce(
          (cheapest, current) =>
            current.estimated_trip_cost < cheapest.estimated_trip_cost
              ? current
              : cheapest,
        );

        recommendations.push({
          transfer_request_id: transferRequestId,
          shipment_id: candidate.shipment_id,
          shipment_number: candidate.shipment_number,
          decision_type: "create_new_trip",
          trip_id: null,
          total_cost: vehicle.estimated_trip_cost,
          cost_breakdown: {
            vehicle_id: vehicle.vehicle_id,
            vehicle_name: vehicle.vehicle_name,
            distance_km: vehicle.distance_km,
            fixed_cost: vehicle.fixed_cost,
            cost_per_km: vehicle.cost_per_km,
            estimated_trip_cost: vehicle.estimated_trip_cost,
          },
          reasoning: LOGISTICS_DECISION_ENGINE_TEXT.success.create_new_trip,
        });

        continue;
      }

      recommendations.push({
        transfer_request_id: transferRequestId,
        shipment_id: candidate.shipment_id,
        shipment_number: candidate.shipment_number,
        decision_type: "defer",
        trip_id: null,
        total_cost: null,
        cost_breakdown: {},
        reasoning: LOGISTICS_DECISION_ENGINE_TEXT.success.defer,
      });
    }

    return {
      transfer_request_id: transferRequestId,
      recommendations,
    };
  }
  static async createSystemLogisticsDecisions(
    transferRequestId: string,
    recommendations: LogisticsDecisionRecommendation[],
    currentUser: CurrentUser,
  ): Promise<LogisticsDecision[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.TRIP_UPDATE)) {
      throw new ForbiddenError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.forbidden_update,
      );
    }

    if (!recommendations.length) {
      return [];
    }

    const transferRequestRows = await sql`
    SELECT
      id,
      status
    FROM transfer_requests
    WHERE id = ${transferRequestId}
    LIMIT 1
  `;

    if (!transferRequestRows.length) {
      throw new NotFoundError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.request_not_found,
      );
    }

    if (transferRequestRows[0].status !== "approved") {
      throw new ValidationError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.transfer_request_not_available,
      );
    }

    const hasInvalidRequest = recommendations.some(
      (recommendation) =>
        recommendation.transfer_request_id !== transferRequestId,
    );

    if (hasInvalidRequest) {
      throw new ValidationError(
        LOGISTICS_DECISION_ENGINE_TEXT.error.transfer_request_not_available,
      );
    }

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
    SELECT
      recommendation.transfer_request_id,
      recommendation.trip_id,
      recommendation.decision_type,
      recommendation.total_cost,
      recommendation.cost_breakdown,
      recommendation.reasoning,
      'system',
      NULL,
      NOW()
    FROM jsonb_to_recordset(
      ${JSON.stringify(recommendations)}::JSONB
    ) AS recommendation(
      transfer_request_id UUID,
      trip_id UUID,
      decision_type TEXT,
      total_cost NUMERIC,
      cost_breakdown JSONB,
      reasoning TEXT
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
  `) as LogisticsDecision[];

    return rows;
  }
}
