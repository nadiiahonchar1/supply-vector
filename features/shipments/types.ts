export type ShipmentStatus =
  | "pending"
  | "in_transit"
  | "completed"
  | "cancelled";

export type Shipment = {
  id: string;

  source_store_id: string;
  destination_store_id: string;

  status: ShipmentStatus;

  created_at: string;
  completed_at: string | null;
};

export type ShipmentItem = {
  id: string;

  shipment_id: string;

  product_id: string;

  quantity: number;
};

export type ShipmentDetailsItem = {
  product_id: string;
  name: string;
  sku: string;
  quantity: number;
};

export type ShipmentDetails = {
  shipment_id: string;

  status: ShipmentStatus;

  created_at: string;
  completed_at: string | null;

  source_store: {
    id: string;
    name: string;
    city: string;
  };

  destination_store: {
    id: string;
    name: string;
    city: string;
  };

  items: ShipmentDetailsItem[];
};

export type ShipmentFilters = {
  status?: ShipmentStatus;
  sourceStoreId?: string;
  destinationStoreId?: string;
};

export type ShipmentRow = {
  shipment_id: string;
  status: ShipmentDetails["status"];
  created_at: string;
  completed_at: string | null;

  source_store_id: string;
  source_store_name: string;
  source_store_city: string;

  destination_store_id: string;
  destination_store_name: string;
  destination_store_city: string;

  product_id: string;
  product_name: string;
  product_sku: string;
  quantity: number;
};

export type ShipmentsStats = {
  pending: number;
  in_transit: number;
  completed: number;
  cancelled: number;
  total: number;
};