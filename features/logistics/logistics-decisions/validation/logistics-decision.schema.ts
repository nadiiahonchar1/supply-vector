import { z } from "zod";

export const createLogisticsDecisionSchema = z
  .object({
    transfer_request_id: z.string().uuid(),

    trip_id: z.string().uuid().nullable().optional(),

    decision_type: z.enum(["add_to_existing_trip", "create_new_trip", "defer"]),

    total_cost: z.number().nonnegative().nullable().optional(),

    cost_breakdown: z.record(z.string(), z.unknown()).optional(),

    reasoning: z.string().trim().min(1),
  })
  .superRefine((data, ctx) => {
    if (data.decision_type === "add_to_existing_trip" && !data.trip_id) {
      ctx.addIssue({
        code: "custom",
        path: ["trip_id"],
        message: "Для додавання до наявної поїздки потрібен trip_id",
      });
    }

    if (
      (data.decision_type === "create_new_trip" ||
        data.decision_type === "defer") &&
      data.trip_id
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["trip_id"],
        message: "Для цього типу рішення trip_id не повинен передаватися",
      });
    }
  });

export const updateLogisticsDecisionStatusSchema = z.object({
  decision_status: z.enum(["accepted", "rejected"]),
});
