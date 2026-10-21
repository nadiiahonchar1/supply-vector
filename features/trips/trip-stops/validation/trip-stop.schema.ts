import { z } from "zod";

export const createTripStopSchema = z.object({
  trip_id: z.string().uuid(),
  store_id: z.string().uuid(),
  sequence: z.number().int().positive(),
  expected_arrival_at: z.string().datetime().nullable().optional(),
});

export const updateTripStopSchema = z.object({
  sequence: z.number().int().positive().optional(),
  expected_arrival_at: z.string().datetime().nullable().optional(),
  actual_arrival_at: z.string().datetime().nullable().optional(),
});
