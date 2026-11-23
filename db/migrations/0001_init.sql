CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =====================================================
-- 1. USERS
-- =====================================================

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,

  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  last_login_at TIMESTAMPTZ,

  created_by UUID REFERENCES users(id),
  deleted_by UUID REFERENCES users(id),
  deleted_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_users_deleted_at
    CHECK (deleted_at IS NULL OR is_active = FALSE)
);

CREATE UNIQUE INDEX idx_users_email_lower
  ON users (LOWER(email));


-- =====================================================
-- 2. ROLES AND PERMISSIONS
-- =====================================================

CREATE TABLE roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  hierarchy_level SMALLINT NOT NULL UNIQUE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_roles_hierarchy_level
    CHECK (hierarchy_level BETWEEN 1 AND 4)
);

INSERT INTO roles (code, name, hierarchy_level)
VALUES
  ('operator', 'Operator', 1),
  ('manager', 'Manager', 2),
  ('admin', 'Admin', 3),
  ('superadmin', 'Superadmin', 4);


CREATE TABLE permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


CREATE TABLE user_roles (
  user_id UUID NOT NULL
    REFERENCES users(id) ON DELETE CASCADE,

  role_id UUID NOT NULL
    REFERENCES roles(id) ON DELETE RESTRICT,

  assigned_by UUID REFERENCES users(id),
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (user_id, role_id)
);


CREATE TABLE role_permissions (
  role_id UUID NOT NULL
    REFERENCES roles(id) ON DELETE CASCADE,

  permission_id UUID NOT NULL
    REFERENCES permissions(id) ON DELETE CASCADE,

  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (role_id, permission_id)
);


-- =====================================================
-- 3. AUTHENTICATION SESSIONS
-- =====================================================

CREATE TABLE sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL
    REFERENCES users(id) ON DELETE CASCADE,

  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sessions_user_id
  ON sessions(user_id);

CREATE INDEX idx_sessions_expires_at
  ON sessions(expires_at);


CREATE TABLE password_resets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL
    REFERENCES users(id) ON DELETE CASCADE,

  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


CREATE TABLE password_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL
    REFERENCES users(id) ON DELETE CASCADE,

  password_hash TEXT NOT NULL,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =====================================================
-- 4. EMPLOYEES
-- =====================================================

CREATE TABLE employees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID UNIQUE
    REFERENCES users(id) ON DELETE SET NULL,

  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,

  phone TEXT,

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_employees_user_id
  ON employees(user_id);

CREATE INDEX idx_employees_active
  ON employees(is_active);


-- =====================================================
-- 5. EMPLOYEE SPECIALIZATIONS
-- =====================================================

CREATE TABLE employee_specializations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  employee_id UUID NOT NULL
    REFERENCES employees(id) ON DELETE CASCADE,

  specialization TEXT NOT NULL,

  valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until DATE,

  created_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_employee_specialization_dates
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE INDEX idx_employee_specializations_employee
  ON employee_specializations(employee_id);


-- =====================================================
-- 6. DEPARTMENTS
-- =====================================================

CREATE TABLE departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  parent_department_id UUID
    REFERENCES departments(id) ON DELETE RESTRICT,

  name TEXT NOT NULL,
  description TEXT,

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_department_not_own_parent
    CHECK (parent_department_id IS NULL OR parent_department_id <> id)
);

CREATE INDEX idx_departments_parent
  ON departments(parent_department_id);

CREATE INDEX idx_departments_active
  ON departments(is_active);


-- =====================================================
-- 7. EMPLOYEE DEPARTMENT MEMBERSHIP HISTORY
-- =====================================================

CREATE TABLE employee_departments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  employee_id UUID NOT NULL
    REFERENCES employees(id) ON DELETE RESTRICT,

  department_id UUID NOT NULL
    REFERENCES departments(id) ON DELETE RESTRICT,

  valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until DATE,

  assigned_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_employee_department_dates
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE INDEX idx_employee_departments_employee
  ON employee_departments(employee_id);

CREATE INDEX idx_employee_departments_department
  ON employee_departments(department_id);

CREATE UNIQUE INDEX idx_employee_departments_active
  ON employee_departments(employee_id, department_id)
  WHERE valid_until IS NULL;


-- =====================================================
-- 8. DEPARTMENT MANAGER HISTORY
-- =====================================================

CREATE TABLE department_managers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  department_id UUID NOT NULL
    REFERENCES departments(id) ON DELETE RESTRICT,

  employee_id UUID NOT NULL
    REFERENCES employees(id) ON DELETE RESTRICT,

  valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until DATE,

  assigned_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_department_manager_dates
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE INDEX idx_department_managers_department
  ON department_managers(department_id);

CREATE INDEX idx_department_managers_employee
  ON department_managers(employee_id);

CREATE UNIQUE INDEX idx_department_managers_active
  ON department_managers(department_id)
  WHERE valid_until IS NULL;


-- =====================================================
-- 9. STORAGE POINTS
-- =====================================================

CREATE TABLE storage_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  name TEXT NOT NULL,
  city TEXT NOT NULL,
  address TEXT NOT NULL,

  latitude NUMERIC(10, 7),
  longitude NUMERIC(10, 7),

  status TEXT NOT NULL DEFAULT 'active',

  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_storage_points_status
    CHECK (status IN ('active', 'unavailable', 'closed')),

  CONSTRAINT chk_storage_points_latitude
    CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),

  CONSTRAINT chk_storage_points_longitude
    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),

  CONSTRAINT uq_storage_points_location
    UNIQUE (name, city, address)
);

CREATE INDEX idx_storage_points_status
  ON storage_points(status);

CREATE INDEX idx_storage_points_city
  ON storage_points(city);


-- =====================================================
-- 10. STORAGE POINT RESPONSIBLES
-- =====================================================

CREATE TABLE storage_point_responsibles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  storage_point_id UUID NOT NULL
    REFERENCES storage_points(id) ON DELETE RESTRICT,

  employee_id UUID NOT NULL
    REFERENCES employees(id) ON DELETE RESTRICT,

  valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
  valid_until DATE,

  assigned_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_storage_responsible_dates
    CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE INDEX idx_storage_responsibles_point
  ON storage_point_responsibles(storage_point_id);

CREATE INDEX idx_storage_responsibles_employee
  ON storage_point_responsibles(employee_id);

CREATE UNIQUE INDEX idx_storage_responsibles_active
  ON storage_point_responsibles(storage_point_id, employee_id)
  WHERE valid_until IS NULL;


-- =====================================================
-- 11. PRODUCTS
-- =====================================================

CREATE TABLE products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  sku TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,

  weight_kg NUMERIC(12, 3),
  volume_m3 NUMERIC(12, 6),

  is_active BOOLEAN NOT NULL DEFAULT TRUE,

  created_by UUID REFERENCES users(id),
  updated_by UUID REFERENCES users(id),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_products_weight
    CHECK (weight_kg IS NULL OR weight_kg >= 0),

  CONSTRAINT chk_products_volume
    CHECK (volume_m3 IS NULL OR volume_m3 >= 0)
);

CREATE INDEX idx_products_name
  ON products(name);

CREATE INDEX idx_products_active
  ON products(is_active);


-- =====================================================
-- 12. AUDIT LOGS
-- =====================================================

CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID REFERENCES users(id) ON DELETE SET NULL,

  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,

  old_values JSONB,
  new_values JSONB,
  metadata JSONB,

  ip_address INET,
  user_agent TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_logs_user
  ON audit_logs(user_id);

CREATE INDEX idx_audit_logs_entity
  ON audit_logs(entity_type, entity_id);

CREATE INDEX idx_audit_logs_created_at
  ON audit_logs(created_at);