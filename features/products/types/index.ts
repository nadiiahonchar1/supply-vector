export type Product = {
  id: string;
  name: string;
  sku: string;
  price: number;
  description: string | null;

  weight_kg: number | null;
  volume_m3: number | null;

  is_active: boolean;

  created_by: string | null;
  updated_by: string | null;

  created_at: string;
  updated_at: string;
};

export type CreateProductInput = {
  name: string;
  sku: string;
  price: number;
  description?: string | null;

  weight_kg?: number | null;
  volume_m3?: number | null;
};

export type UpdateProductInput = Partial<CreateProductInput> & {
  is_active?: boolean;
};
