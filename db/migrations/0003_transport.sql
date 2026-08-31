-- =====================================
-- VEHICLES
-- =====================================
 
CREATE TABLE vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  name TEXT NOT NULL,
  type TEXT NOT NULL,
 
  capacity_weight NUMERIC(10,2) NOT NULL CHECK (capacity_weight > 0),
  capacity_volume NUMERIC(10,2) CHECK (capacity_volume IS NULL OR capacity_volume > 0),
 
  cost_per_km NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (cost_per_km >= 0),
  fixed_cost NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fixed_cost >= 0),
 
  available_from TIMESTAMP,
  available_to TIMESTAMP,
 
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
 
  CHECK (
    available_to IS NULL
    OR available_from IS NULL
    OR available_to >= available_from
  )
);
 
CREATE INDEX idx_vehicles_is_active ON vehicles(is_active);
 
-- =====================================
-- TRIPS
-- =====================================
 
CREATE TABLE trips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  vehicle_id UUID NOT NULL REFERENCES vehicles(id),
  origin_store_id UUID NOT NULL REFERENCES stores(id),
 
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'ready', 'in_transit', 'delivered', 'cancelled')),
 
  departure_at TIMESTAMP,
  expected_arrival_at TIMESTAMP,
 
  distance_km NUMERIC(10,2) CHECK (distance_km IS NULL OR distance_km >= 0),
  cost NUMERIC(10,2) CHECK (cost IS NULL OR cost >= 0),
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
 
  CHECK (
    expected_arrival_at IS NULL
    OR departure_at IS NULL
    OR expected_arrival_at >= departure_at
  )
);
 
CREATE INDEX idx_trips_status ON trips(status);
CREATE INDEX idx_trips_vehicle_id ON trips(vehicle_id);
CREATE INDEX idx_trips_origin_store_id ON trips(origin_store_id);
 
-- =====================================
-- TRIP STOPS
-- =====================================

CREATE TABLE trip_stops (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  store_id UUID NOT NULL REFERENCES stores(id),
 
  sequence INTEGER NOT NULL CHECK (sequence > 0),
 
  expected_arrival_at TIMESTAMP,
  actual_arrival_at TIMESTAMP,
 
  UNIQUE (trip_id, sequence)
);
 
CREATE INDEX idx_trip_stops_trip_id ON trip_stops(trip_id);
CREATE INDEX idx_trip_stops_store_id ON trip_stops(store_id);
 
-- =====================================
-- TRIP ITEMS (cargo)
-- =====================================
 
CREATE TABLE trip_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  transfer_request_id UUID NOT NULL REFERENCES transfer_requests(id),
 
  pickup_stop_id UUID REFERENCES trip_stops(id),
  dropoff_stop_id UUID NOT NULL REFERENCES trip_stops(id),
 
  quantity INTEGER NOT NULL CHECK (quantity > 0),
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE INDEX idx_trip_items_trip_id ON trip_items(trip_id);
CREATE INDEX idx_trip_items_transfer_request_id ON trip_items(transfer_request_id);
 