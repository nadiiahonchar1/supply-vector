export type TripStatus =
  | "planned"
  | "ready"
  | "in_transit"
  | "delivered"
  | "cancelled";

export type Trip = {
  id: string;
  vehicle_id: string;
  origin_store_id: string;
  status: TripStatus;
  departure_at: string | null;
  expected_arrival_at: string | null;
  distance_km: number | null;
  cost: number | null;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
};

export type CreateTripInput = {
  vehicle_id: string;
  origin_store_id: string;
  departure_at?: string | null;
  expected_arrival_at?: string | null;
  distance_km?: number | null;
  cost?: number | null;
};

export type UpdateTripInput = {
  status?: TripStatus;
  departure_at?: string | null;
  expected_arrival_at?: string | null;
  distance_km?: number | null;
  cost?: number | null;
};
