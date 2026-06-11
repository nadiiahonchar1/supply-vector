"use client";

import { useRouter } from "next/navigation";
import Link from "next/link";

import type { ShipmentDetails, ShipmentStatus } from "../types";
import { ShipmentStatusBadge } from "./shipment-status-badge";
import { updateShipmentStatusAction } from "../actions/update-shipment-status";

type Props = {
  shipments: ShipmentDetails[];
};

export function ShipmentsTable({ shipments }: Props) {
  const router = useRouter();

  async function handleStatusUpdate(
    shipmentId: string,
    status: ShipmentStatus,
    currentStatus: ShipmentStatus,
  ) {
    await updateShipmentStatusAction({
      shipmentId,
      status,
      currentStatus,
    });

    router.refresh();
  }

  async function handleCancel(shipment: ShipmentDetails) {
    const confirmed = window.confirm(
      "Are you sure you want to cancel this shipment?",
    );

    if (!confirmed) return;

    await handleStatusUpdate(
      shipment.shipment_id,
      "cancelled",
      shipment.status,
    );
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
            <th align="left">Completed</th>
            <th align="left">Actions</th>
            <th align="left">Link</th>
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
                {s.completed_at
                  ? new Date(s.completed_at).toLocaleString()
                  : "-"}
              </td>

              <td>
                {s.status === "pending" && (
                  <>
                    <button
                      onClick={() =>
                        handleStatusUpdate(
                          s.shipment_id,
                          "in_transit",
                          s.status,
                        )
                      }
                    >
                      Start delivery
                    </button>{" "}
                    <button onClick={() => handleCancel(s)}>Cancel</button>
                  </>
                )}

                {s.status === "in_transit" && (
                  <button
                    onClick={() =>
                      handleStatusUpdate(s.shipment_id, "completed", s.status)
                    }
                  >
                    Complete
                  </button>
                )}

                {(s.status === "completed" || s.status === "cancelled") && (
                  <span style={{ color: "#888" }}>No actions</span>
                )}
              </td>

              <td>
                <Link href={`/shipments/${s.shipment_id}`}>View details</Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
