export type Vehicle = {
  id: string;
  name: string;
  type: string;

  capacity_weight: number;
  capacity_volume: number | null;

  cost_per_km: number;
  fixed_cost: number;

  available_from: string | null;
  available_to: string | null;

  is_active: boolean;

  created_by: string | null;
  updated_by: string | null;

  created_at: string;
  updated_at: string;
};

export type CreateVehicleInput = {
  name: string;
  type: string;

  capacity_weight: number;
  capacity_volume?: number | null;

  cost_per_km: number;
  fixed_cost: number;

  available_from?: string | null;
  available_to?: string | null;
};

export type UpdateVehicleInput = Partial<CreateVehicleInput> & {
  is_active?: boolean;
};
