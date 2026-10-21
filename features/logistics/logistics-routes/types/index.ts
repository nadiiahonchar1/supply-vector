export type LogisticsRoute = {
  id: string;
  store_a_id: string;
  store_b_id: string;
  distance_km: number;
  estimated_duration_minutes: number | null;
  is_active: boolean;
  created_at: string | null;
  updated_at: string | null;
};

export type CreateLogisticsRouteInput = {
  store_a_id: string;
  store_b_id: string;
  distance_km: number;
  estimated_duration_minutes?: number | null;
};

export type UpdateLogisticsRouteInput = {
  distance_km?: number;
  estimated_duration_minutes?: number | null;
  is_active?: boolean;
};
