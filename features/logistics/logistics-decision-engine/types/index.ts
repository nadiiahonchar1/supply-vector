import type { LogisticsDecisionType } from "@/features/logistics/logistics-decisions/types";

export type LogisticsShipmentCandidate = {
  shipment_id: string;
  shipment_number: string;
  remaining_quantity: number;
};

export type LogisticsExistingTripCandidate = {
  trip_id: string;
  vehicle_id: string;
  vehicle_name: string;
  status: "planned" | "ready";
  distance_km: number | null;
  cost: number | null;
  pickup_stop_id: string;
  pickup_sequence: number;
  dropoff_stop_id: string;
  dropoff_sequence: number;
};

export type LogisticsTripCandidate = LogisticsShipmentCandidate & {
  trips: LogisticsExistingTripCandidate[];
};

export type LogisticsDecisionRecommendation = {
  transfer_request_id: string;
  shipment_id: string;
  shipment_number: string;
  decision_type: LogisticsDecisionType;
  trip_id: string | null;
  total_cost: number | null;
  cost_breakdown: Record<string, unknown>;
  reasoning: string;
};

export type LogisticsDecisionEngineResult = {
  transfer_request_id: string;
  recommendations: LogisticsDecisionRecommendation[];
};
