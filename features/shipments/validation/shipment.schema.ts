import { z } from "zod";

export const createShipmentSchema = z.object({
  transfer_request_id: z.string().uuid(),
  quantity: z.number().int().positive(),
});

export const updateShipmentSchema = z.object({
  status: z.enum(["pending", "in_transit", "completed", "cancelled"]),
});
