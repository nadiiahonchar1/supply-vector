import { sql } from "@/db";
import { hashPassword } from "@/lib/auth/password";

async function seed() {
  console.log("🌱 Seeding database...");

  // =========================
  // ROLES
  // =========================
  const roles = await sql`
    INSERT INTO roles (code, name)
    VALUES
      ('superadmin', 'Super Admin'),
      ('admin', 'Admin'),
      ('manager', 'Manager'),
      ('viewer', 'Viewer')
    RETURNING *;
  `;

  const superadminRole = roles.find((r) => r.code === "superadmin");
  const adminRole = roles.find((r) => r.code === "admin");
  const managerRole = roles.find((r) => r.code === "manager");
  const viewerRole = roles.find((r) => r.code === "viewer");

  // =========================
  // USERS
  // =========================
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
    RETURNING *;
  `;

  const superadmin = users.find((u) => u.email === "superadmin@test.com")!;
  const admin = users.find((u) => u.email === "admin@test.com")!;
  const manager = users.find((u) => u.email === "manager@test.com")!;
  const viewer = users.find((u) => u.email === "viewer@test.com")!;

  // =========================
  // USER ROLES
  // =========================
  await sql`
    INSERT INTO user_roles (user_id, role_id)
    VALUES
      (${superadmin.id}, ${superadminRole!.id}),
      (${admin.id}, ${adminRole!.id}),
      (${manager.id}, ${managerRole!.id}),
      (${viewer.id}, ${viewerRole!.id});
  `;

  // =========================
  // STORES
  // =========================
  const stores = await sql`
    INSERT INTO stores (name, city, address)
    VALUES
      ('Kyiv Central', 'Kyiv', 'Main Street 1'),
      ('Lviv Hub', 'Lviv', 'Freedom Ave 10')
    RETURNING *;
  `;

  const kyiv = stores[0];
  const lviv = stores[1];

  // =========================
  // USER STORES (manager + admin access)
  // =========================
  await sql`
    INSERT INTO user_stores (user_id, store_id)
    VALUES
      (${admin.id}, ${kyiv.id}),
      (${admin.id}, ${lviv.id}),
      (${manager.id}, ${kyiv.id}),
      (${manager.id}, ${lviv.id}),
      (${viewer.id}, ${kyiv.id});
  `;

  // =========================
  // PRODUCTS
  // =========================
  const products = await sql`
    INSERT INTO products (name, sku, price, description, is_active)
    VALUES
      ('iPhone 15', 'APL-IP15', 999.99, 'Apple smartphone', true),
      ('Samsung S24', 'SMS-S24', 899.99, 'Samsung flagship', true),
      ('MacBook Pro', 'APL-MBP', 1999.99, 'Apple laptop', true)
    RETURNING *;
  `;

  // =========================
  // INVENTORY
  // =========================
  await sql`
    INSERT INTO inventory (store_id, product_id, quantity, min_stock)
    VALUES
      (${kyiv.id}, ${products[0].id}, 10, 2),
      (${kyiv.id}, ${products[1].id}, 5, 2),
      (${lviv.id}, ${products[2].id}, 3, 1);
  `;

  // =========================
  // SHIPMENT
  // =========================
  const shipments = await sql`
    INSERT INTO shipments (
      source_store_id,
      destination_store_id,
      status,
      created_by
    )
    VALUES
      (${kyiv.id}, ${lviv.id}, 'pending', ${admin.id})
    RETURNING *;
  `;

  const shipment = shipments[0];

  // =========================
  // SHIPMENT ITEMS
  // =========================
  const shipmentItems = await sql`
    INSERT INTO shipment_items (shipment_id, product_id, quantity)
    VALUES
      (${shipment.id}, ${products[0].id}, 2),
      (${shipment.id}, ${products[1].id}, 1)
    RETURNING *;
  `;

  // =========================
  // INVENTORY MOVEMENTS (initial example)
  // =========================
  await sql`
    INSERT INTO inventory_movements (
      store_id,
      product_id,
      quantity_change,
      movement_type,
      shipment_id,
      shipment_item_id,
      created_by
    )
    VALUES
      (
        ${kyiv.id},
        ${products[0].id},
        -2,
        'transfer_out',
        ${shipment.id},
        ${shipmentItems[0].id},
        ${admin.id}
      );
  `;

  console.log("✅ Seed completed successfully");
}

seed()
  .catch((err) => {
    console.error("❌ Seed error:", err);
    process.exit(1);
  })
  .finally(() => process.exit(0));
