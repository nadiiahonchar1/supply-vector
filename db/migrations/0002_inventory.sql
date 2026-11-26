-- =====================================================
-- 1. INVENTORY
-- =====================================================

CREATE TABLE inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  product_id UUID NOT NULL
    REFERENCES products(id) ON DELETE RESTRICT,

  quantity INTEGER NOT NULL DEFAULT 0,
  reserved_quantity INTEGER NOT NULL DEFAULT 0,
  blocked_quantity INTEGER NOT NULL DEFAULT 0,

  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_inventory_quantity
    CHECK (quantity >= 0),

  CONSTRAINT chk_inventory_reserved
    CHECK (reserved_quantity >= 0),

  CONSTRAINT chk_inventory_blocked
    CHECK (blocked_quantity >= 0),

  CONSTRAINT chk_inventory_allocated
    CHECK (reserved_quantity + blocked_quantity <= quantity),

  CONSTRAINT uq_inventory_point_product
    UNIQUE (storage_point_id, product_id)
);

CREATE INDEX idx_inventory_storage_point
  ON inventory(storage_point_id);

CREATE INDEX idx_inventory_product
  ON inventory(product_id);


-- =====================================================
-- 2. INVENTORY RECEIPTS
-- =====================================================

CREATE TABLE inventory_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  receipt_number TEXT NOT NULL UNIQUE,

  comment TEXT,

  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_inventory_receipts_point
  ON inventory_receipts(storage_point_id);

CREATE INDEX idx_inventory_receipts_received_at
  ON inventory_receipts(received_at);


CREATE TABLE inventory_receipt_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  receipt_id UUID NOT NULL
    REFERENCES inventory_receipts(id) ON DELETE RESTRICT,

  product_id UUID NOT NULL
    REFERENCES products(id) ON DELETE RESTRICT,

  supplier_name TEXT,

  quantity INTEGER NOT NULL CHECK (quantity > 0),

  comment TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_inventory_receipt_items_receipt
  ON inventory_receipt_items(receipt_id);

CREATE INDEX idx_inventory_receipt_items_product
  ON inventory_receipt_items(product_id);


-- =====================================================
-- 3. PHYSICAL INVENTORY MOVEMENTS
-- =====================================================

CREATE TABLE inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  product_id UUID NOT NULL
    REFERENCES products(id) ON DELETE RESTRICT,

  movement_type TEXT NOT NULL,

  quantity INTEGER NOT NULL CHECK (quantity > 0),

  quantity_before INTEGER NOT NULL CHECK (quantity_before >= 0),
  quantity_after INTEGER NOT NULL CHECK (quantity_after >= 0),

  reference_type TEXT,
  reference_id UUID,

  reason TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_inventory_movement_type
    CHECK (
      movement_type IN (
        'receipt',
        'shipment_load',
        'shipment_receive',
        'shipment_return',
        'salvage_return',
        'writeoff',
        'adjustment'
      )
    ),

  CONSTRAINT chk_inventory_movement_balance
    CHECK (
      (
        movement_type IN (
          'receipt',
          'shipment_receive',
          'shipment_return',
          'salvage_return'
        )
        AND quantity_after = quantity_before + quantity
      )
      OR
      (
        movement_type IN ('shipment_load', 'writeoff')
        AND quantity_after = quantity_before - quantity
      )
      OR
      (
        movement_type = 'adjustment'
        AND quantity = ABS(quantity_after - quantity_before)
        AND quantity_after <> quantity_before
      )
    )
);

CREATE INDEX idx_inventory_movements_point_product
  ON inventory_movements(storage_point_id, product_id);

CREATE INDEX idx_inventory_movements_reference
  ON inventory_movements(reference_type, reference_id);

CREATE INDEX idx_inventory_movements_created_at
  ON inventory_movements(created_at);


-- =====================================================
-- 4. INVENTORY RESERVATIONS
-- =====================================================

CREATE TABLE inventory_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  inventory_id UUID NOT NULL
    REFERENCES inventory(id) ON DELETE RESTRICT,

  transfer_request_source_id UUID NOT NULL,

  reserved_quantity INTEGER NOT NULL CHECK (reserved_quantity > 0),

  consumed_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (consumed_quantity >= 0),

  released_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (released_quantity >= 0),

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_reservation_accounting
    CHECK (
      consumed_quantity + released_quantity <= reserved_quantity
    )
);

CREATE INDEX idx_inventory_reservations_inventory
  ON inventory_reservations(inventory_id);

CREATE INDEX idx_inventory_reservations_source
  ON inventory_reservations(transfer_request_source_id);


-- =====================================================
-- 5. RESERVATION MOVEMENTS
-- =====================================================

CREATE TABLE inventory_reservation_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  reservation_id UUID NOT NULL
    REFERENCES inventory_reservations(id) ON DELETE RESTRICT,

  movement_type TEXT NOT NULL,

  quantity INTEGER NOT NULL CHECK (quantity > 0),

  reference_type TEXT,
  reference_id UUID,

  reason TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_reservation_movement_type
    CHECK (
      movement_type IN ('reserve', 'consume', 'release')
    )
);

CREATE INDEX idx_reservation_movements_reservation
  ON inventory_reservation_movements(reservation_id);

CREATE INDEX idx_reservation_movements_reference
  ON inventory_reservation_movements(reference_type, reference_id);


-- =====================================================
-- 6. INVENTORY BLOCKS
-- =====================================================

CREATE TABLE inventory_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  inventory_id UUID NOT NULL
    REFERENCES inventory(id) ON DELETE RESTRICT,

  reason TEXT NOT NULL,

  initial_quantity INTEGER NOT NULL
    CHECK (initial_quantity > 0),

  unblocked_quantity INTEGER NOT NULL DEFAULT 0
    CHECK (unblocked_quantity >= 0),

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_inventory_block_reason
    CHECK (
      reason IN (
        'damage',
        'suspected_damage',
        'loss',
        'other'
      )
    ),

  CONSTRAINT chk_inventory_block_accounting
    CHECK (unblocked_quantity <= initial_quantity)
);

CREATE INDEX idx_inventory_blocks_inventory
  ON inventory_blocks(inventory_id);


-- =====================================================
-- 7. INVENTORY BLOCK MOVEMENTS
-- =====================================================

CREATE TABLE inventory_block_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  block_id UUID NOT NULL
    REFERENCES inventory_blocks(id) ON DELETE RESTRICT,

  movement_type TEXT NOT NULL,

  quantity INTEGER NOT NULL CHECK (quantity > 0),

  reference_type TEXT,
  reference_id UUID,

  reason TEXT,
  comment TEXT,

  created_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_block_movement_type
    CHECK (movement_type IN ('block', 'unblock'))
);

CREATE INDEX idx_inventory_block_movements_block
  ON inventory_block_movements(block_id);

CREATE INDEX idx_inventory_block_movements_reference
  ON inventory_block_movements(reference_type, reference_id);


-- =====================================================
-- 8. CLOSED STORAGE POINT INVENTORY INSPECTIONS
-- =====================================================

CREATE TABLE storage_point_inventory_inspections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  product_id UUID NOT NULL
    REFERENCES products(id) ON DELETE RESTRICT,

  inspected_quantity INTEGER NOT NULL
    CHECK (inspected_quantity >= 0),

  available_quantity INTEGER NOT NULL
    CHECK (available_quantity >= 0),

  inspected_by UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  comment TEXT,

  inspected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_inspection_available_quantity
    CHECK (available_quantity <= inspected_quantity),

  CONSTRAINT uq_storage_point_inspection
    UNIQUE (storage_point_id, product_id, inspected_at)
);

CREATE INDEX idx_storage_point_inspections_point
  ON storage_point_inventory_inspections(storage_point_id);