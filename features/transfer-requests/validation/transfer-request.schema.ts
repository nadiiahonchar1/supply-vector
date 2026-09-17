import { z } from "zod";

const prioritySchema = z.enum(["critical", "high", "normal", "low"]);

const statusSchema = z.enum(["pending", "approved", "fulfilled", "cancelled"]);

export const createTransferRequestSchema = z.object({
  source_store_id: z.string().uuid(),
  destination_store_id: z.string().uuid(),
  product_id: z.string().uuid(),
  quantity: z.number().int().positive(),
  priority: prioritySchema,
  earliest_delivery: z.string().datetime().nullable().optional(),
  latest_delivery: z.string().datetime().nullable().optional(),
});

export const updateTransferRequestSchema = z.object({
  priority: prioritySchema.optional(),
  status: statusSchema.optional(),
  earliest_delivery: z.string().datetime().nullable().optional(),
  latest_delivery: z.string().datetime().nullable().optional(),
});
