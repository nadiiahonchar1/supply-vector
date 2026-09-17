export type TransferRequestPriority = "critical" | "high" | "normal" | "low";

export type TransferRequestStatus =
  | "pending"
  | "approved"
  | "fulfilled"
  | "cancelled";

export type TransferRequest = {
  id: string;
  source_store_id: string;
  destination_store_id: string;
  product_id: string;
  quantity: number;
  priority: TransferRequestPriority;
  status: TransferRequestStatus;
  earliest_delivery: string | null;
  latest_delivery: string | null;
  shipment_id: string | null;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
  cancelled_at: string | null;
};

export type CreateTransferRequestInput = {
  source_store_id: string;
  destination_store_id: string;
  product_id: string;
  quantity: number;
  priority: TransferRequestPriority;
  earliest_delivery?: string | null;
  latest_delivery?: string | null;
};

export type UpdateTransferRequestInput = {
  priority?: TransferRequestPriority;
  status?: TransferRequestStatus;
  earliest_delivery?: string | null;
  latest_delivery?: string | null;
};
