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
-- min_stock (existing) plays the role of "safety stock" in the
-- AvailableForTransfer formula from the concept doc:
--   AvailableForTransfer = quantity - reserved_quantity - min_stock
 
ALTER TABLE inventory
  ADD COLUMN reserved_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (reserved_quantity >= 0),
  ADD COLUMN max_stock INTEGER;
 
ALTER TABLE inventory
  ADD CONSTRAINT chk_inventory_max_stock
    CHECK (max_stock IS NULL OR max_stock >= min_stock),
  ADD CONSTRAINT chk_inventory_reserved_within_quantity
    CHECK (reserved_quantity <= quantity);
 
COMMENT ON COLUMN inventory.reserved_quantity IS
  'Sum of active inventory_reservations for this row. Not directly editable — kept in sync when reservations are created/released.';
COMMENT ON COLUMN inventory.max_stock IS
  'Optional target ceiling for this product at this store. NULL = unconstrained.';
 
-- =====================================
-- TRANSFER REQUESTS
-- =====================================
-- The "demand" layer: a request to move a quantity of one product
-- from a source store to a destination store. Independent of *how*
-- it's eventually moved — shipment_id is set once it's fulfilled by
-- an actual shipment. May gain a trip_id instead/in addition once
-- Етап 3 (consolidated trips) exists.
 
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
-- One row per active hold a transfer_request places on a store's
-- stock. Kept separate from inventory.reserved_quantity (a running
-- total) so a specific reservation can be released precisely when
-- its request is fulfilled or cancelled, without guessing which
-- request contributed which amount.
 
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
 
-- Fast lookup of *active* (not yet released) reservations — the hot
-- path when computing AvailableForTransfer for a given inventory row.
CREATE INDEX idx_inventory_reservations_active ON inventory_reservations(inventory_id)
  WHERE released_at IS NULL;
 