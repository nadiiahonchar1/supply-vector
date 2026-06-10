import { getLowStockQuery } from "../queries/get-low-stock-query";

export async function LowStockWidget() {
  const items = await getLowStockQuery();

  return (
    <div style={{ padding: 16, border: "1px solid #ddd" }}>
      <h3>Low stock alerts</h3>

      {items.length === 0 ? (
        <p>All good ✅</p>
      ) : (
        <ul>
          {items.map((i) => (
            <li key={`${i.product_id}-${i.store_name}`}>
              <b>{i.product_name}</b> ({i.sku}) — {i.quantity} left
              <br />
              <small>
                Store: {i.store_name} ({i.city})
              </small>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
