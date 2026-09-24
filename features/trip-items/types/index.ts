export type TripItem = {
  id: string;
  trip_id: string;
  transfer_request_id: string;
  pickup_stop_id: string | null;
  dropoff_stop_id: string;
  quantity: number;
  created_at: string;
};

export type CreateTripItemInput = {
  trip_id: string;
  transfer_request_id: string;
  pickup_stop_id?: string | null;
  dropoff_stop_id: string;
  quantity: number;
};

export type UpdateTripItemInput = {
  quantity?: number;
  pickup_stop_id?: string | null;
  dropoff_stop_id?: string;
};
