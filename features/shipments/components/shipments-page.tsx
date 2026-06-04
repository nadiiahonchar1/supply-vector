import type { ShipmentDetails, ShipmentFilters } from "../types";
import type { StoreOption } from "@/features/stores/types";
import { ShipmentsTable } from "./shipments-table";
import { ShipmentsFilters } from "./shipments-filters";

type Props = {
  shipments: ShipmentDetails[];
  filters: ShipmentFilters;
  stores: StoreOption[];
};

export function ShipmentsPage({ shipments, stores, filters }: Props) {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>

      <ShipmentsFilters stores={stores} />

      <ShipmentsTable shipments={shipments} />
    </div>
  );
}
