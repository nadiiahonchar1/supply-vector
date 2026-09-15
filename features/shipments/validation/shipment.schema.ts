import { z } from "zod";

export const createShipmentSchema = z.object({
  transfer_request_id: z.string().uuid(),
});

export const updateShipmentSchema = z.object({
  status: z.enum(["pending", "in_transit", "completed", "cancelled"]),
});
