export type Inventory = {
  id: string;
  store_id: string;
  product_id: string;

  quantity: number;
  reserved_quantity: number;
  min_stock: number;
  max_stock: number | null;

  created_at: string | null;
  updated_at: string | null;
};

export type InventoryWithDetails = Inventory & {
  store_name: string;
  city: string;

  product_name: string;
  sku: string;
};

export type CreateInventoryInput = {
  store_id: string;
  product_id: string;
  quantity?: number;
  min_stock?: number;
  max_stock?: number | null;
};

export type UpdateInventoryInput = {
  min_stock?: number;
  max_stock?: number | null;
};

export type AdjustInventoryInput = {
  quantity_change: number;
  movement_type: "purchase" | "sale" | "adjustment" | "return";
};
