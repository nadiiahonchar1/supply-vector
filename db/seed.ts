import { sql } from "./index";

async function seed() {
  console.log("🌱 Seeding database...");

  // =========================
  // ROLES
  // =========================
  const roles = await sql`
    INSERT INTO roles (code, name)
    VALUES
      ('admin', 'Admin'),
      ('manager', 'Manager'),
      ('viewer', 'Viewer')
    RETURNING *;
  `;

  const adminRole = roles.find((r) => r.code === "admin");
  const managerRole = roles.find((r) => r.code === "manager");

  // =========================
  // USERS
  // =========================
  const users = await sql`
    INSERT INTO users (
      email,
      password_hash,
      first_name,
      last_name,
      is_active
    )
    VALUES
      ('admin@test.com', 'hashed_password', 'Admin', 'User', true),
      ('manager@test.com', 'hashed_password', 'Manager', 'User', true)
    RETURNING *;
  `;

  const adminUser = users[0];
  const managerUser = users[1];

  // =========================
  // USER ROLES
  // =========================
  await sql`
    INSERT INTO user_roles (user_id, role_id)
    VALUES
      (${adminUser.id}, ${adminRole!.id}),
      (${managerUser.id}, ${managerRole!.id});
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

  const kyivStore = stores[0];
  const lvivStore = stores[1];

  // =========================
  // USER STORES
  // =========================
  await sql`
    INSERT INTO user_stores (user_id, store_id)
    VALUES
      (${managerUser.id}, ${kyivStore.id}),
      (${managerUser.id}, ${lvivStore.id});
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
      (${kyivStore.id}, ${products[0].id}, 10, 2),
      (${kyivStore.id}, ${products[1].id}, 5, 2),
      (${lvivStore.id}, ${products[2].id}, 3, 1);
  `;

  // =========================
  // SHIPMENTS
  // =========================
  const shipments = await sql`
    INSERT INTO shipments (
      source_store_id,
      destination_store_id,
      status,
      created_by
    )
    VALUES
      (${kyivStore.id}, ${lvivStore.id}, 'pending', ${adminUser.id})
    RETURNING *;
  `;

  const shipment = shipments[0];

  // =========================
  // SHIPMENT ITEMS
  // =========================
  await sql`
    INSERT INTO shipment_items (shipment_id, product_id, quantity)
    VALUES
      (${shipment.id}, ${products[0].id}, 2),
      (${shipment.id}, ${products[1].id}, 1);
  `;

  // =========================
  // INVENTORY MOVEMENTS (optional seed)
  // =========================
  await sql`
    INSERT INTO inventory_movements (
      store_id,
      product_id,
      quantity_change,
      reason,
      shipment_id,
      created_by
    )
    VALUES
      (${kyivStore.id}, ${products[0].id}, -2, 'seed shipment', ${shipment.id}, ${adminUser.id});
  `;

  console.log("✅ Seeding completed");
}

seed()
  .catch((err) => {
    console.error("❌ Seed error:", err);
    process.exit(1);
  })
  .finally(async () => {
    process.exit(0);
  });
