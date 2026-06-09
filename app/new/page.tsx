import { getStoresQuery } from "@/features/stores/queries/get-stores-query";
// import { getProductsQuery } from "@/features/products/queries/get-products-query";
import { CreateShipmentForm } from "@/features/shipments/components/shipment-form";

const products = [
  { id: "p1", name: "iPhone 15", sku: "APL-IP15" },
  { id: "p2", name: "Samsung S24", sku: "SMS-S24" },
];

export default async function Page() {
  //   const [stores, products] = await Promise.all([
  //     getStoresQuery(),
  //     getProductsQuery(),
  //   ]);

  const [stores] = await Promise.all([getStoresQuery()]);

  return (
    <div style={{ padding: 20 }}>
      <h1>Create Shipment</h1>

      <CreateShipmentForm stores={stores} products={products} />
    </div>
  );
}
