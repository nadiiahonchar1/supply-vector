import { getInventory } from "@/features/inventory/api/get-inventory";
import { getKpis } from "@/features/analytics/api/get-kpis";
import { InventoryTable } from "@/features/inventory/components/inventory-table";
import { KpiCard } from "@/features/analytics/components/kpi-card";

export default async function HomePage() {
  const [inventory, kpis] = await Promise.all([getInventory(), getKpis()]);

  return (
    <main className="p-8 space-y-8">
      <div>
        <h1 className="text-3xl font-bold">SupplyVector Dashboard</h1>
        <p className="text-gray-500">Logistics & inventory system</p>
      </div>

      {/* KPI SECTION */}
      <div className="grid grid-cols-4 gap-4">
        <KpiCard label="Stores" value={kpis.totalStores} />
        <KpiCard label="Products" value={kpis.totalProducts} />
        <KpiCard label="Low Stock" value={kpis.lowStockItems} />
        <KpiCard label="Critical Ratio" value={kpis.criticalRatio} />
      </div>

      {/* INVENTORY TABLE */}
      <InventoryTable items={inventory} />
    </main>
  );
}
