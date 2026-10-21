import { z } from "zod";

export const createLogisticsRouteSchema = z
  .object({
    store_a_id: z.string().uuid(),
    store_b_id: z.string().uuid(),
    distance_km: z.number().nonnegative(),
    estimated_duration_minutes: z
      .number()
      .int()
      .nonnegative()
      .nullable()
      .optional(),
  })
  .refine((data) => data.store_a_id !== data.store_b_id, {
    message: "Склад відправлення та склад призначення мають відрізнятися",
    path: ["store_b_id"],
  });

export const updateLogisticsRouteSchema = z.object({
  distance_km: z.number().nonnegative().optional(),
  estimated_duration_minutes: z
    .number()
    .int()
    .nonnegative()
    .nullable()
    .optional(),
  is_active: z.boolean().optional(),
});
