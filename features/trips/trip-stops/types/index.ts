export type TripStop = {
  id: string;
  trip_id: string;
  store_id: string;
  sequence: number;
  expected_arrival_at: string | null;
  actual_arrival_at: string | null;
};

export type CreateTripStopInput = {
  trip_id: string;
  store_id: string;
  sequence: number;
  expected_arrival_at?: string | null;
};

export type UpdateTripStopInput = {
  sequence?: number;
  expected_arrival_at?: string | null;
  actual_arrival_at?: string | null;
};
