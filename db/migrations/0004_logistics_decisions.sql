-- =====================================
-- LOGISTICS ROUTES
-- =====================================
 
CREATE TABLE logistics_routes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  store_a_id UUID NOT NULL REFERENCES stores(id),
  store_b_id UUID NOT NULL REFERENCES stores(id),
 
  distance_km NUMERIC(10,2) NOT NULL CHECK (distance_km >= 0),
  estimated_duration_minutes INTEGER
    CHECK (estimated_duration_minutes IS NULL OR estimated_duration_minutes >= 0),
 
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
 
  CHECK (store_a_id < store_b_id),
  UNIQUE (store_a_id, store_b_id)
);
 
CREATE INDEX idx_logistics_routes_store_a_id ON logistics_routes(store_a_id);
CREATE INDEX idx_logistics_routes_store_b_id ON logistics_routes(store_b_id);
 
-- =====================================
-- LOGISTICS DECISIONS
-- =====================================
 
CREATE TABLE logistics_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  transfer_request_id UUID REFERENCES transfer_requests(id),
  trip_id UUID REFERENCES trips(id),
 
  decision_type TEXT NOT NULL
    CHECK (decision_type IN ('add_to_existing_trip', 'create_new_trip', 'defer')),
 
  total_cost NUMERIC(12,2),
  cost_breakdown JSONB,
 
  reasoning TEXT,
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE INDEX idx_logistics_decisions_transfer_request_id ON logistics_decisions(transfer_request_id);
CREATE INDEX idx_logistics_decisions_trip_id ON logistics_decisions(trip_id);
CREATE INDEX idx_logistics_decisions_created_at ON logistics_decisions(created_at);
 