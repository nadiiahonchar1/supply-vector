export function ShipmentsSkeleton() {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipments</h1>

      <div style={{ display: "flex", gap: 12, marginBottom: 16 }}>
        <div style={{ width: 140, height: 32, background: "#eee" }} />
        <div style={{ width: 160, height: 32, background: "#eee" }} />
        <div style={{ width: 160, height: 32, background: "#eee" }} />
        <div style={{ width: 80, height: 32, background: "#eee" }} />
      </div>

      {/* table skeleton */}
      <div style={{ display: "grid", gap: 10 }}>
        {Array.from({ length: 5 }).map((_, i) => (
          <div
            key={i}
            style={{
              height: 40,
              background: "#f2f2f2",
              borderRadius: 6,
            }}
          />
        ))}
      </div>
    </div>
  );
}
