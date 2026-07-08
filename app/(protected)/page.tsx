import { getKpisQuery } from "@/features/analytics/queries/get-kpis-query";
import { getInventoryQuery } from "@/features/inventory/queries/get-inventory-query";
import { InventoryTable } from "@/features/inventory/components/inventory-table";
import { KpiCard } from "@/features/analytics/components/kpi-card";
import { LowStockWidget } from "@/features/inventory/components/low-stock-widget";

export default async function HomePage() {
  const [inventory, kpis] = await Promise.all([
    getInventoryQuery(),
    getKpisQuery(),
  ]);

  return (
    <main className="p-8 space-y-8">
      <div>
        <h1 className="text-3xl font-bold">SupplyVector Dashboard</h1>
        <p className="text-gray-500">Logistics & inventory system</p>
      </div>

      <div className="grid grid-cols-4 gap-4">
        <KpiCard label="Stores" value={kpis.totalStores} />
        <KpiCard label="Products" value={kpis.totalProducts} />
        <KpiCard label="Low Stock" value={kpis.lowStockItems} />
        <KpiCard label="Critical Ratio" value={kpis.criticalRatio} />
      </div>

      <InventoryTable items={inventory} />
      <div className="grid grid-cols-4 gap-4">
        <LowStockWidget />
      </div>
    </main>
  );
}
