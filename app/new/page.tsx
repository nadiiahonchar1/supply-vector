import { getStoresQuery } from "@/features/stores/queries/get-stores-query";
import { getInventoryQuery } from "@/features/inventory/queries/get-inventory-query";
// import { getProductsQuery } from "@/features/products/queries/get-products-query";
import { CreateShipmentForm } from "@/features/shipments/components/shipment-form";

const products = [
  {
    id: "24d84edb-2800-4414-a6b6-a7dfb9f2f5a2",
    name: "iPhone 15",
    sku: "APL-IP15",
  },
  {
    id: "0371c8f1-b2f0-4878-bf73-1da629cc8891",
    name: "Samsung S24",
    sku: "SMS-S24",
  },
];

export default async function Page() {
  //   const [stores, products] = await Promise.all([
  //     getStoresQuery(),
  //     getProductsQuery(),
  //   ]);

  const [stores, inventory] = await Promise.all([
    getStoresQuery(),
    getInventoryQuery(),
  ]);

  return (
    <div style={{ padding: 20 }}>
      <h1>Create Shipment</h1>

      <CreateShipmentForm
        stores={stores}
        products={products}
        inventory={inventory ?? []}
      />
    </div>
  );
}
