import { z } from "zod";

export const createVehicleSchema = z.object({
  name: z.string().trim().min(1),
  type: z.string().trim().min(1),

  capacity_weight: z.number().positive(),

  capacity_volume: z.number().positive().nullable().optional(),

  cost_per_km: z.number().nonnegative(),
  fixed_cost: z.number().nonnegative(),

  available_from: z.string().datetime().nullable().optional(),

  available_to: z.string().datetime().nullable().optional(),
});

export const updateVehicleSchema = createVehicleSchema.partial().extend({
  is_active: z.boolean().optional(),
});
