import { z } from "zod";

const statusSchema = z.enum([
  "planned",
  "ready",
  "in_transit",
  "delivered",
  "cancelled",
]);

export const createTripSchema = z.object({
  vehicle_id: z.string().uuid(),
  origin_store_id: z.string().uuid(),
  departure_at: z.string().datetime().nullable().optional(),
  expected_arrival_at: z.string().datetime().nullable().optional(),
  distance_km: z.number().nonnegative().nullable().optional(),
  cost: z.number().nonnegative().nullable().optional(),
});

export const updateTripSchema = z.object({
  status: statusSchema.optional(),
  departure_at: z.string().datetime().nullable().optional(),
  expected_arrival_at: z.string().datetime().nullable().optional(),
  distance_km: z.number().nonnegative().nullable().optional(),
  cost: z.number().nonnegative().nullable().optional(),
});
