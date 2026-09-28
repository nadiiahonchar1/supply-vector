export type LogisticsDecisionType =
  | "add_to_existing_trip"
  | "create_new_trip"
  | "defer";

export type LogisticsDecisionSource = "system" | "manual";

export type LogisticsDecision = {
  id: string;
  transfer_request_id: string | null;
  trip_id: string | null;
  decision_type: LogisticsDecisionType;
  total_cost: number | null;
  cost_breakdown: Record<string, unknown>;
  reasoning: string;
  decision_source: LogisticsDecisionSource;
  decided_by: string | null;
  created_at: string;
};
