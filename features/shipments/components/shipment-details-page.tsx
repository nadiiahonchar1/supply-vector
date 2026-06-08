import type { ShipmentDetails } from "../types";

type Props = {
  shipment: ShipmentDetails;
};

export function ShipmentDetailsPage({ shipment }: Props) {
  return (
    <div style={{ padding: 20 }}>
      <h1>Shipment {shipment.shipment_id}</h1>

      <h2>Status</h2>

      <p>{shipment.status}</p>

      <h2>Route</h2>

      <p>
        {shipment.source_store.name}
        {" → "}
        {shipment.destination_store.name}
      </p>

      <h2>Products</h2>

      <table>
        <thead>
          <tr>
            <th align="left">Name</th>
            <th align="left">SKU</th>
            <th align="left">Quantity</th>
          </tr>
        </thead>

        <tbody>
          {shipment.items.map((item) => (
            <tr key={item.product_id}>
              <td>{item.name}</td>
              <td>{item.sku}</td>
              <td>{item.quantity}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
