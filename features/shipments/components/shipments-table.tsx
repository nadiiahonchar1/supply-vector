"use client";

import { useRouter } from "next/navigation";

import type { ShipmentDetails, ShipmentStatus } from "../types";
import { ShipmentStatusBadge } from "./shipment-status-badge";
import { updateShipmentStatus } from "../api/update-shipment-status";

type Props = {
  shipments: ShipmentDetails[];
};

export function ShipmentsTable({ shipments }: Props) {
  const router = useRouter();

  async function handleStatusUpdate(
    shipmentId: string,
    status: ShipmentStatus,
  ) {
    await updateShipmentStatus(shipmentId, status);

    router.refresh();
  }

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
            <th align="left">Actions</th>
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

              <td>
                {s.status !== "completed" && (
                  <button
                    onClick={() =>
                      handleStatusUpdate(s.shipment_id, "completed")
                    }
                  >
                    Complete
                  </button>
                )}{" "}
                {s.status !== "cancelled" && (
                  <button
                    onClick={() =>
                      handleStatusUpdate(s.shipment_id, "cancelled")
                    }
                  >
                    Cancel
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
