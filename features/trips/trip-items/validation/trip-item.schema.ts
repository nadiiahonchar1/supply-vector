import { z } from "zod";

export const createTripItemSchema = z.object({
  trip_id: z.string().uuid(),
  transfer_request_id: z.string().uuid(),
  pickup_stop_id: z.string().uuid().nullable().optional(),
  dropoff_stop_id: z.string().uuid(),
  quantity: z.number().int().positive(),
});

export const updateTripItemSchema = z.object({
  quantity: z.number().int().positive().optional(),
  pickup_stop_id: z.string().uuid().nullable().optional(),
  dropoff_stop_id: z.string().uuid().optional(),
});
