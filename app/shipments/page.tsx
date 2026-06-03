import { getShipmentsQuery } from "@/features/shipments/queries/get-shipments-query";
import { ShipmentsPage } from "@/features/shipments/components/shipments-page";

export default async function Page() {
  const shipments = await getShipmentsQuery();

  return <ShipmentsPage shipments={shipments} />;
}
