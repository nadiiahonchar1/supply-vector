ALTER TABLE stores
  ADD COLUMN latitude NUMERIC(8,6)
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  ADD COLUMN longitude NUMERIC(9,6)
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180);