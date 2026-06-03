import type { ShipmentDetails, ShipmentFilters } from "../types";
import { ShipmentsTable } from "./shipments-table";
import { ShipmentsFilters } from "./shipments-filters";

type Props = {
  shipments: ShipmentDetails[];
  filters: ShipmentFilters;
};

export function ShipmentsPage({ shipments }: Props) {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>

      <ShipmentsFilters />

      <ShipmentsTable shipments={shipments} />
    </div>
  );
}
