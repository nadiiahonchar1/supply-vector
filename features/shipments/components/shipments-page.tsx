import type {
  ShipmentDetails,
  ShipmentFilters,
  ShipmentsStats as ShipmentsStatsType,
} from "../types";
import type { StoreOption } from "../components/shipment-form";
import { ShipmentsTable } from "./shipments-table";
import { ShipmentsFilters } from "./shipments-filters";
import { ShipmentsStats } from "./shipments-stats";

type Props = {
  shipments: ShipmentDetails[];
  filters: ShipmentFilters;
  stores: StoreOption[];
  stats: ShipmentsStatsType;
};

export function ShipmentsPage({ shipments, stores, filters, stats }: Props) {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>
      <ShipmentsFilters stores={stores} filters={filters} />
      <ShipmentsTable shipments={shipments} />
      <ShipmentsStats {...stats} />
    </div>
  );
}
