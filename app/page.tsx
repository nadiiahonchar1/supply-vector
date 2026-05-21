import { getInventory } from "@/features/inventory/api/get-inventory";
import { InventoryTable } from "@/features/inventory/components/inventory-table";

export default async function HomePage() {
  const inventory = await getInventory();

  return (
    <main className="p-8">
      <div className="mb-6">
        <h1 className="text-3xl font-bold">SupplyVector Dashboard</h1>

        <p className="text-gray-500">Inventory monitoring system</p>
      </div>

      <InventoryTable items={inventory} />
    </main>
  );
}
