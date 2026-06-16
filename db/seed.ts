import { sql } from "@/db";
import { hashPassword } from "@/lib/auth/password";

async function seed() {
  console.log("🌱 Seeding database...");

  // =====================================
  // ROLES
  // =====================================
  const roles = await sql`
    INSERT INTO roles (code, name)
    VALUES
      ('superadmin', 'Super Admin'),
      ('admin', 'Admin'),
      ('manager', 'Manager'),
      ('viewer', 'Viewer')
    ON CONFLICT (code) DO NOTHING
    RETURNING *;
  `;

  const allRoles = await sql`SELECT * FROM roles`;

  const superadminRole = allRoles.find((r) => r.code === "superadmin");
  const adminRole = allRoles.find((r) => r.code === "admin");
  const managerRole = allRoles.find((r) => r.code === "manager");
  const viewerRole = allRoles.find((r) => r.code === "viewer");

  // =====================================
  // USERS (1 per role)
  // =====================================
  const superadminPassword = await hashPassword("superadmin123");
  const adminPassword = await hashPassword("admin123");
  const managerPassword = await hashPassword("manager123");
  const viewerPassword = await hashPassword("viewer123");

  const users = await sql`
    INSERT INTO users (
      email,
      password_hash,
      first_name,
      last_name,
      is_active
    )
    VALUES
      (
        'superadmin@test.com',
        ${superadminPassword},
        'Super',
        'Admin',
        true
      ),
      (
        'admin@test.com',
        ${adminPassword},
        'Admin',
        'User',
        true
      ),
      (
        'manager@test.com',
        ${managerPassword},
        'Manager',
        'User',
        true
      ),
      (
        'viewer@test.com',
        ${viewerPassword},
        'Viewer',
        'User',
        true
      )
    ON CONFLICT (email) DO NOTHING
    RETURNING *;
  `;

  const allUsers = await sql`SELECT * FROM users`;

  const superadmin = allUsers.find((u) => u.email === "superadmin@test.com");
  const admin = allUsers.find((u) => u.email === "admin@test.com");
  const manager = allUsers.find((u) => u.email === "manager@test.com");
  const viewer = allUsers.find((u) => u.email === "viewer@test.com");

  // =====================================
  // USER ROLES
  // =====================================
  await sql`
    INSERT INTO user_roles (user_id, role_id)
    VALUES
      (${superadmin!.id}, ${superadminRole!.id}),
      (${admin!.id}, ${adminRole!.id}),
      (${manager!.id}, ${managerRole!.id}),
      (${viewer!.id}, ${viewerRole!.id})
    ON CONFLICT DO NOTHING;
  `;

  // =====================================
  // STORES
  // =====================================
  const stores = await sql`
    INSERT INTO stores (name, city, address)
    VALUES
      ('Kyiv Central', 'Kyiv', 'Main Street 1'),
      ('Lviv Hub', 'Lviv', 'Freedom Ave 10')
    ON CONFLICT DO NOTHING
    RETURNING *;
  `;

  const allStores = await sql`SELECT * FROM stores`;

  const kyiv = allStores[0];
  const lviv = allStores[1];

  // =====================================
  // USER STORES
  // =====================================
  await sql`
    INSERT INTO user_stores (user_id, store_id)
    VALUES
      (${admin!.id}, ${kyiv.id}),
      (${manager!.id}, ${kyiv.id}),
      (${viewer!.id}, ${kyiv.id})
    ON CONFLICT DO NOTHING;
  `;

  // =====================================
  // PRODUCTS
  // =====================================
  const products = await sql`
    INSERT INTO products (name, sku, price, description, is_active)
    VALUES
      ('iPhone 15', 'APL-IP15', 999.99, 'Apple smartphone', true),
      ('Samsung S24', 'SMS-S24', 899.99, 'Samsung flagship', true),
      ('MacBook Pro', 'APL-MBP', 1999.99, 'Apple laptop', true)
    ON CONFLICT DO NOTHING
    RETURNING *;
  `;

  const allProducts = await sql`SELECT * FROM products`;

  // =====================================
  // INVENTORY
  // =====================================
  await sql`
    INSERT INTO inventory (store_id, product_id, quantity, min_stock)
    VALUES
      (${kyiv.id}, ${allProducts[0].id}, 10, 2),
      (${kyiv.id}, ${allProducts[1].id}, 5, 2),
      (${lviv.id}, ${allProducts[2].id}, 3, 1)
    ON CONFLICT DO NOTHING;
  `;

  console.log("✅ Seed completed successfully");
}

seed()
  .catch((err) => {
    console.error("❌ Seed error:", err);
    process.exit(1);
  })
  .finally(() => process.exit(0));
