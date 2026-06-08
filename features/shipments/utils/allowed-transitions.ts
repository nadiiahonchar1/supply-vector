import { ShipmentStatus } from "../types";

export const allowedTransitions: Record<ShipmentStatus, ShipmentStatus[]> = {
  pending: ["in_transit", "cancelled"],
  in_transit: ["completed", "cancelled"],
  completed: [],
  cancelled: [],
};
