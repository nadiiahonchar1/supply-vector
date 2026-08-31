ALTER TABLE products
  ADD COLUMN weight_kg NUMERIC(10,3) CHECK (weight_kg IS NULL OR weight_kg > 0),
  ADD COLUMN volume_m3 NUMERIC(10,4) CHECK (volume_m3 IS NULL OR volume_m3 > 0);
