type Props = {
  quantity: number;
  minStock: number;
};

export function StockStatusBadge({ quantity, minStock }: Props) {
  const isLow = quantity < minStock;

  return (
    <div
      className={`
        inline-flex items-center rounded-full px-3 py-1 text-sm font-medium
        ${isLow ? "bg-red-100 text-red-700" : "bg-green-100 text-green-700"}
      `}
    >
      {isLow ? "Low Stock" : "In Stock"}
    </div>
  );
}
