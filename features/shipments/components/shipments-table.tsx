import type { ShipmentDetails } from "../types";
import { ShipmentStatusBadge } from "./shipment-status-badge";

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
          {shipments.map((s) => (
            <tr key={s.shipment_id}>
              <td>
                <ShipmentStatusBadge status={s.status} />
              </td>

              <td>
                {s.source_store.name} ({s.source_store.city})
              </td>

              <td>
                {s.destination_store.name} ({s.destination_store.city})
              </td>

              <td>{s.items.length}</td>

              <td>{new Date(s.created_at).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
