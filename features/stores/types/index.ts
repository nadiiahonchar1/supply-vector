export type Store = {
  id: string;
  name: string;
  city: string;
  address: string;

  latitude: number | null;
  longitude: number | null;

  is_storage_node: boolean;
  max_capacity: number | null;

  is_active: boolean;

  created_by: string | null;
  updated_by: string | null;

  created_at: string;
  updated_at: string;
};

export type CreateStoreInput = {
  name: string;
  city: string;
  address: string;

  latitude?: number | null;
  longitude?: number | null;

  is_storage_node?: boolean;
  max_capacity?: number | null;
};

export type UpdateStoreInput = Partial<CreateStoreInput> & {
  is_active?: boolean;
};
