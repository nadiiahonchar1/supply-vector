import { z } from "zod";

export const createStoreSchema = z.object({
  name: z.string().trim().min(1),
  city: z.string().trim().min(1),
  address: z.string().trim().min(1),

  latitude: z.number().min(-90).max(90).nullable().optional(),

  longitude: z.number().min(-180).max(180).nullable().optional(),

  is_storage_node: z.boolean().optional(),

  max_capacity: z.number().positive().nullable().optional(),
});

export const updateStoreSchema = createStoreSchema.partial();

export type CreateStoreSchema = z.infer<typeof createStoreSchema>;
export type UpdateStoreSchema = z.infer<typeof updateStoreSchema>;
