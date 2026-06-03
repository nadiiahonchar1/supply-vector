import type { ShipmentDetails } from "../types";

type Props = {
  shipments: ShipmentDetails[];
};

export function ShipmentsTable({ shipments }: Props) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse" }}>
        <thead>
          <tr>
            <th align="left">Status</th>
            <th align="left">Source</th>
            <th align="left">Destination</th>
            <th align="left">Items</th>
            <th align="left">Created</th>
          </tr>
        </thead>

        <tbody>
          {shipments.map((shipment) => (
            <tr key={shipment.shipment_id}>
              <td>{shipment.status}</td>

              <td>
                {shipment.source_store.name} ({shipment.source_store.city})
              </td>

              <td>
                {shipment.destination_store.name} (
                {shipment.destination_store.city})
              </td>

              <td>{shipment.items.length}</td>

              <td>{new Date(shipment.created_at).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
