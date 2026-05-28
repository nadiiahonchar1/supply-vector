export type InventoryItem = {
  store_id: string;
  store_name: string;
  city: string;

  product_id: string;
  product_name: string;
  sku: string;

  quantity: number;
  min_stock: number;
};

export type LowStockItem = InventoryItem;

export type InventoryFilters = {
  city?: string;
  lowStock?: boolean;
};
