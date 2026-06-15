CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =====================================
-- USERS & AUTH
-- =====================================

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,

  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  last_login_at TIMESTAMP,

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL
);

CREATE TABLE user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,

  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE user_stores (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  store_id UUID NOT NULL,

  PRIMARY KEY (user_id, store_id)
);

-- =====================================
-- STORES
-- =====================================

CREATE TABLE stores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  name TEXT NOT NULL,
  city TEXT NOT NULL,
  address TEXT NOT NULL,

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),

  UNIQUE (name, city, address)
);

ALTER TABLE user_stores
ADD CONSTRAINT fk_user_stores_store
FOREIGN KEY (store_id)
REFERENCES stores(id)
ON DELETE CASCADE;

-- =====================================
-- PRODUCTS
-- =====================================

CREATE TABLE products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  name TEXT NOT NULL,
  sku TEXT NOT NULL UNIQUE,

  price NUMERIC(10,2) NOT NULL,

  description TEXT,

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- =====================================
-- INVENTORY
-- =====================================

CREATE TABLE inventory (
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

CREATE TABLE shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  source_store_id UUID NOT NULL REFERENCES stores(id),
  destination_store_id UUID NOT NULL REFERENCES stores(id),

  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (
      status IN (
        'pending',
        'in_transit',
        'completed',
        'cancelled'
      )
    ),

  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),

  completed_at TIMESTAMP,

  CHECK (source_store_id <> destination_store_id)
);

CREATE TABLE shipment_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  shipment_id UUID NOT NULL
    REFERENCES shipments(id)
    ON DELETE CASCADE,

  product_id UUID NOT NULL
    REFERENCES products(id),

  quantity INTEGER NOT NULL
    CHECK (quantity > 0)
);

-- =====================================
-- INVENTORY MOVEMENTS
-- =====================================

CREATE TABLE inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  store_id UUID NOT NULL
    REFERENCES stores(id),

  product_id UUID NOT NULL
    REFERENCES products(id),

  quantity_change INTEGER NOT NULL,

  reason TEXT NOT NULL,

  shipment_id UUID
    REFERENCES shipments(id),

  created_by UUID
    REFERENCES users(id),

  created_at TIMESTAMP DEFAULT NOW()
);