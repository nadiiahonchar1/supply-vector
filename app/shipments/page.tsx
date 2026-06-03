import { getShipmentsQuery } from "@/features/shipments/queries/get-shipments-query";
import { ShipmentsPage } from "@/features/shipments/components/shipments-page";
import { ShipmentStatus } from "@/features/shipments/types";

type SearchParams = {
  status?: string;
  sourceStoreId?: string;
  destinationStoreId?: string;
};

const allowedStatuses: ShipmentStatus[] = [
  "pending",
  "in_transit",
  "completed",
  "cancelled",
];

function isShipmentStatus(value: string): value is ShipmentStatus {
  return allowedStatuses.includes(value as ShipmentStatus);
}

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;

  const status = params.status
    ? isShipmentStatus(params.status)
      ? params.status
      : undefined
    : undefined;

  const filters = {
    status,
    sourceStoreId: params.sourceStoreId,
    destinationStoreId: params.destinationStoreId,
  };

  const shipments = await getShipmentsQuery(filters);

  return <ShipmentsPage shipments={shipments} filters={filters} />;
}
