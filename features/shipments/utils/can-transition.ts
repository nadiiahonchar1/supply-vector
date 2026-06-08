import { ShipmentStatus } from "../types";
import { allowedTransitions } from "./allowed-transitions";

export function canTransition(from: ShipmentStatus, to: ShipmentStatus) {
  return allowedTransitions[from].includes(to);
}
