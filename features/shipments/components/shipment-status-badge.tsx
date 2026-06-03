import type { ShipmentStatus } from "../types";

type Props = {
  status: ShipmentStatus;
};

export function ShipmentStatusBadge({ status }: Props) {
  const config = getStatusConfig(status);

  return (
    <span
      style={{
        padding: "4px 8px",
        borderRadius: 6,
        fontSize: 12,
        fontWeight: 600,
        backgroundColor: config.bg,
        color: config.color,
        display: "inline-block",
      }}
    >
      {config.label}
    </span>
  );
}

function getStatusConfig(status: ShipmentStatus) {
  switch (status) {
    case "pending":
      return {
        label: "Pending",
        bg: "#FFF4D6",
        color: "#B7791F",
      };

    case "in_transit":
      return {
        label: "In transit",
        bg: "#D6ECFF",
        color: "#1E5EFF",
      };

    case "completed":
      return {
        label: "Completed",
        bg: "#D6F5E3",
        color: "#1F7A4D",
      };

    case "cancelled":
      return {
        label: "Cancelled",
        bg: "#FFE0E0",
        color: "#B42318",
      };
  }
}
