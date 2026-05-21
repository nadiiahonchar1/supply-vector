import { InventoryItem } from "../types";
import { StockStatusBadge } from "./stock-status-badge";

type Props = {
  items: InventoryItem[];
};

export function InventoryTable({ items }: Props) {
  return (
    <div className="overflow-x-auto rounded-2xl border">
      <table className="min-w-full text-sm">
        <thead className="bg-gray-100">
          <tr>
            <th className="px-4 py-3 text-left">Store</th>
            <th className="px-4 py-3 text-left">City</th>
            <th className="px-4 py-3 text-left">Product</th>
            <th className="px-4 py-3 text-left">SKU</th>
            <th className="px-4 py-3 text-left">Quantity</th>
            <th className="px-4 py-3 text-left">Min Stock</th>
            <th className="px-4 py-3 text-left">Status</th>
          </tr>
        </thead>

        <tbody>
          {items.map((item) => (
            <tr
              key={`${item.store_id}-${item.product_id}`}
              className="border-t"
            >
              <td className="px-4 py-3">{item.store_name}</td>

              <td className="px-4 py-3">{item.city}</td>

              <td className="px-4 py-3">{item.product_name}</td>

              <td className="px-4 py-3">{item.sku}</td>

              <td className="px-4 py-3">{item.quantity}</td>

              <td className="px-4 py-3">{item.min_stock}</td>

              <td className="px-4 py-3">
                <StockStatusBadge
                  quantity={item.quantity}
                  minStock={item.min_stock}
                />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
