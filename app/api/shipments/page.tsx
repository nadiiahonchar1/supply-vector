import { getShipmentsQuery } from "@/features/shipments/queries/get-shipments-query";

export default async function ShipmentsPage() {
  const shipments = await getShipmentsQuery();

  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>

      <pre>{JSON.stringify(shipments, null, 2)}</pre>
    </div>
  );
}
