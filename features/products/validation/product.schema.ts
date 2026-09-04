import { z } from "zod";

export const createProductSchema = z.object({
  name: z.string().trim().min(1),
  sku: z.string().trim().min(1),
  price: z.number().nonnegative(),

  description: z.string().trim().nullable().optional(),

  weight_kg: z.number().positive().nullable().optional(),

  volume_m3: z.number().positive().nullable().optional(),
});

export const updateProductSchema = createProductSchema.partial().extend({
  is_active: z.boolean().optional(),
});

export type CreateProductSchema = z.infer<typeof createProductSchema>;

export type UpdateProductSchema = z.infer<typeof updateProductSchema>;
