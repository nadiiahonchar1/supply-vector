import { z } from "zod";

export const createLogisticsDecisionSchema = z.object({
  transfer_request_id: z.string().uuid(),

  trip_id: z.string().uuid().nullable().optional(),

  decision_type: z.enum(["add_to_existing_trip", "create_new_trip", "defer"]),

  total_cost: z.number().nonnegative().nullable().optional(),

  cost_breakdown: z.record(z.string(), z.unknown()).optional(),

  reasoning: z.string().min(1),

});
