export type LogisticsDecisionType =
  | "add_to_existing_trip"
  | "create_new_trip"
  | "defer";

export type LogisticsDecisionSource = "system" | "manual";

export type LogisticsDecisionStatus =
  | "pending"
  | "accepted"
  | "rejected"
  | "superseded";

export type LogisticsDecision = {
  id: string;
  transfer_request_id: string | null;
  shipment_id: string | null;
  trip_id: string | null;
  decision_type: LogisticsDecisionType;
  total_cost: number | null;
  cost_breakdown: Record<string, unknown>;
  reasoning: string;
  decision_source: LogisticsDecisionSource;
  decision_status: LogisticsDecisionStatus | null;
  decided_by: string | null;
  created_at: string;
};

export type CreateLogisticsDecisionInput = {
  transfer_request_id: string;
  trip_id?: string | null;
  decision_type: LogisticsDecisionType;
  total_cost?: number | null;
  cost_breakdown?: Record<string, unknown>;
  reasoning: string;
  decision_source?: LogisticsDecisionSource;
};

export type LogisticsDecisionDetails = LogisticsDecision & {
  shipment: {
    id: string;
    shipment_number: string;
    status: string;
    source_store: {
      id: string;
      name: string;
      city: string;
    };
    destination_store: {
      id: string;
      name: string;
      city: string;
    };
    product: {
      id: string;
      name: string;
      sku: string;
    } | null;
    quantity: number | null;
  } | null;

  transfer_request: {
    id: string;
    status: string;
    priority: string;
    quantity: number;
    earliest_delivery: string | null;
    latest_delivery: string | null;
  } | null;

  trip: {
    id: string;
    status: string;
    distance_km: number | null;
    cost: number | null;
    vehicle: {
      id: string;
      name: string;
      type: string;
    };
  } | null;
};