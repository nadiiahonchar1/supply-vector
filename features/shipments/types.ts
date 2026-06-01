export type Shipment = {
  id: string;

  source_store_id: string;
  destination_store_id: string;

  status: "pending" | "in_transit" | "completed" | "cancelled";

  created_at: string;
  completed_at: string | null;
};

export type ShipmentItem = {
  id: string;

  shipment_id: string;

  product_id: string;

  quantity: number;
};