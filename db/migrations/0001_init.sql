CREATE EXTENSION IF NOT EXISTS "pgcrypto";
 
-- =====================================
-- USERS & AUTH
-- =====================================
 
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
 
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
 
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
 
  last_login_at TIMESTAMP,
 
  created_by UUID REFERENCES users(id),
  deleted_by UUID REFERENCES users(id),
  deleted_at TIMESTAMP,
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
 
CREATE TABLE IF NOT EXISTS roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL
);
 
CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);
 
CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 
  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMP NOT NULL,
 
  created_at TIMESTAMP DEFAULT NOW(),
  last_used_at TIMESTAMP DEFAULT NOW()
);
 
CREATE TABLE IF NOT EXISTS password_resets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 
  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMP NOT NULL,
  used_at TIMESTAMP
);
 
CREATE TABLE IF NOT EXISTS password_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  password_hash TEXT NOT NULL,
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  user_id UUID REFERENCES users(id),
 
  action TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_id UUID,
 
  meta JSONB,
  ip_address TEXT,
  user_agent TEXT,
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);
 
-- =====================================
-- STORES
-- =====================================
 
CREATE TABLE IF NOT EXISTS stores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  name TEXT NOT NULL,
  city TEXT NOT NULL,
  address TEXT NOT NULL,
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
 
  UNIQUE (name, city, address)
);
 
CREATE TABLE IF NOT EXISTS user_stores (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  store_id UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, store_id)
);
 
-- =====================================
-- PRODUCTS
-- =====================================
 
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  name TEXT NOT NULL,
  sku TEXT NOT NULL UNIQUE,
  price NUMERIC(10,2) NOT NULL,
 
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
 
-- =====================================
-- INVENTORY
-- =====================================
 
CREATE TABLE IF NOT EXISTS inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  store_id UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
 
  quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  min_stock INTEGER NOT NULL DEFAULT 0 CHECK (min_stock >= 0),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
 
  UNIQUE (store_id, product_id)
);
 
-- =====================================
-- SHIPMENTS
-- =====================================
 
CREATE TABLE IF NOT EXISTS shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  shipment_number TEXT NOT NULL UNIQUE,
 
  source_store_id UUID NOT NULL REFERENCES stores(id),
  destination_store_id UUID NOT NULL REFERENCES stores(id),
 
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'in_transit', 'completed', 'cancelled')),
 
  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  completed_at TIMESTAMP,
 
  CHECK (source_store_id <> destination_store_id)
);
 
CREATE INDEX IF NOT EXISTS idx_shipments_status ON shipments(status);
 
CREATE TABLE IF NOT EXISTS shipment_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  shipment_id UUID NOT NULL REFERENCES shipments(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES products(id),
 
  quantity INTEGER NOT NULL CHECK (quantity > 0)
);
 
-- =====================================
-- INVENTORY MOVEMENTS
-- =====================================
 
CREATE TABLE IF NOT EXISTS inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 
  store_id UUID NOT NULL REFERENCES stores(id),
  product_id UUID NOT NULL REFERENCES products(id),
 
  quantity_change INTEGER NOT NULL,
  quantity_before INTEGER NOT NULL,
  quantity_after INTEGER NOT NULL,
 
  movement_type TEXT NOT NULL CHECK (
    movement_type IN (
      'purchase',
      'sale',
      'transfer_in',
      'transfer_out',
      'adjustment',
      'return'
    )
  ),
 
  shipment_id UUID REFERENCES shipments(id),
  shipment_item_id UUID REFERENCES shipment_items(id),
 
  created_by UUID REFERENCES users(id),
 
  created_at TIMESTAMP DEFAULT NOW()
);
 
CREATE INDEX IF NOT EXISTS idx_inventory_movements_store_id ON inventory_movements(store_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_product_id ON inventory_movements(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_movements_created_at ON inventory_movements(created_at);
 
UPDATE roles
SET
    code = 'operator',
    name = 'Operator'
WHERE code = 'viewer';