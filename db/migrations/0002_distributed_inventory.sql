-- =====================================
-- STORES — warehouse characteristics
-- =====================================
 
ALTER TABLE stores
  ADD COLUMN is_storage_node BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN max_capacity NUMERIC(12,2);
 
COMMENT ON COLUMN stores.is_storage_node IS
  'Whether this store may act as a source of stock for other stores (participates in outbound transfers), not just a point of sale.';
COMMENT ON COLUMN stores.max_capacity IS
  'Optional ceiling on total stock this store can hold. NULL = unconstrained.';
 
-- =====================================
-- INVENTORY — reservations + target stock
-- =====================================
 
ALTER TABLE inventory
  ADD COLUMN reserved_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (reserved_quantity >= 0),
  ADD COLUMN max_stock INTEGER;
 
ALTER TABLE inventory
  ADD CONSTRAINT chk_inventory_max_stock
    CHECK (max_stock IS NULL OR max_stock >= min_stock),
  ADD CONSTRAINT chk_inventory_reserved_within_quantity
    CHECK (reserved_quantity <= quantity);
  
-- =====================================
-- TRANSFER REQUESTS
-- =====================================
 
CREATE TABLE transfer_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  source_store_id UUID NOT NULL REFERENCES stores(id),
  destination_store_id UUID NOT NULL REFERENCES stores(id),
  product_id UUID NOT NULL REFERENCES products(id),
 
  quantity INTEGER NOT NULL CHECK (quantity > 0),
 
  priority TEXT NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('critical', 'high', 'normal', 'low')),
 
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'fulfilled', 'cancelled')),
 
  earliest_delivery TIMESTAMP,
  latest_delivery TIMESTAMP,
 
  shipment_id UUID REFERENCES shipments(id),
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  cancelled_at TIMESTAMP,
 
  CHECK (source_store_id <> destination_store_id),
  CHECK (
    latest_delivery IS NULL
    OR earliest_delivery IS NULL
    OR latest_delivery >= earliest_delivery
  )
);
 
CREATE INDEX idx_transfer_requests_status ON transfer_requests(status);
CREATE INDEX idx_transfer_requests_source_store ON transfer_requests(source_store_id);
CREATE INDEX idx_transfer_requests_destination_store ON transfer_requests(destination_store_id);
CREATE INDEX idx_transfer_requests_priority ON transfer_requests(priority);
 
-- =====================================
-- INVENTORY RESERVATIONS
-- =====================================
 
CREATE TABLE inventory_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  transfer_request_id UUID NOT NULL REFERENCES transfer_requests(id) ON DELETE CASCADE,
  inventory_id UUID NOT NULL REFERENCES inventory(id),
 
  quantity INTEGER NOT NULL CHECK (quantity > 0),
 
  released_at TIMESTAMP,
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE INDEX idx_inventory_reservations_inventory_id ON inventory_reservations(inventory_id);
CREATE INDEX idx_inventory_reservations_transfer_request_id ON inventory_reservations(transfer_request_id); 
CREATE INDEX idx_inventory_reservations_active ON inventory_reservations(inventory_id)
  WHERE released_at IS NULL;
 