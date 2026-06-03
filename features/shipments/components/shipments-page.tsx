import type { ShipmentDetails } from "../types";
import { ShipmentsTable } from "./shipments-table";

type Props = {
  shipments: ShipmentDetails[];
};

export function ShipmentsPage({ shipments }: Props) {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>

      <ShipmentsTable shipments={shipments} />
    </div>
  );
}
