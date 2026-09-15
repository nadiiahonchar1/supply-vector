export type ShipmentStatus =
  | "pending"
  | "in_transit"
  | "completed"
  | "cancelled";

export type Shipment = {
  id: string;
  shipment_number: string;
  source_store_id: string;
  destination_store_id: string;
  status: ShipmentStatus;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
};

export type ShipmentItem = {
  id: string;
  shipment_id: string;
  product_id: string;
  quantity: number;
};

export type CreateShipmentInput = {
  transfer_request_id: string;
};

export type UpdateShipmentInput = {
  status: ShipmentStatus;
};
