import { getStoresQuery } from "@/features/stores/queries/get-stores-query";
import { getProductsQuery } from "@/features/products/queries/get-products-query";
import { CreateShipmentForm } from "@/features/shipments/components/shipment-form";

export default async function Page() {
  const [stores, products] = await Promise.all([
    getStoresQuery(),
    getProductsQuery(),
  ]);

  return (
    <div style={{ padding: 20 }}>
      <h1>Create Shipment</h1>

      <CreateShipmentForm stores={stores} products={products} />
    </div>
  );
}
