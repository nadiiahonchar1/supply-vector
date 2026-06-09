import type { ShipmentsStats } from "../types";

export function ShipmentsStats(props: ShipmentsStats) {
  return (
    <div
      style={{
        display: "flex",
        gap: 16,
        marginBottom: 24,
        flexWrap: "wrap",
      }}
    >
      <StatCard title="Total" value={props.total} />
      <StatCard title="Pending" value={props.pending} />
      <StatCard title="In Transit" value={props.in_transit} />
      <StatCard title="Completed" value={props.completed} />
      <StatCard title="Cancelled" value={props.cancelled} />
    </div>
  );
}

function StatCard({ title, value }: { title: string; value: number }) {
  return (
    <div
      style={{
        border: "1px solid #ddd",
        padding: 16,
        minWidth: 140,
        borderRadius: 8,
      }}
    >
      <div>{title}</div>

      <div
        style={{
          fontSize: 24,
          fontWeight: 600,
          marginTop: 8,
        }}
      >
        {value}
      </div>
    </div>
  );
}
