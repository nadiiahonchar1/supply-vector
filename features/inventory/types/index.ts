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

export type InventoryFilters = {
  store_id?: string;
  product_id?: string;
  city?: string;
  low_stock?: boolean;
};

export type InventoryMovementType =
  | "purchase"
  | "sale"
  | "transfer_in"
  | "transfer_out"
  | "adjustment"
  | "return";

export type InventoryMovement = {
  id: string;
  store_id: string;
  store_name: string;
  product_id: string;
  product_name: string;
  sku: string;

  quantity_change: number;
  quantity_before: number;
  quantity_after: number;

  movement_type: InventoryMovementType;
  shipment_id: string | null;
  shipment_item_id: string | null;
  created_by: string | null;
  created_at: string | null;
};

export type InventoryMovementFilters = {
  store_id?: string;
  product_id?: string;
  movement_type?: InventoryMovementType;
};