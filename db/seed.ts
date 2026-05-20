import { sql } from "./index";

async function seed() {
  // STORES
  const [kyiv] = await sql`
    INSERT INTO stores (name, city, address)
    VALUES ('Kyiv Central', 'Kyiv', 'Khreshchatyk 1')
    RETURNING *
  `;

  const [lviv] = await sql`
    INSERT INTO stores (name, city, address)
    VALUES ('Lviv Hub', 'Lviv', 'Shevchenka 10')
    RETURNING *
  `;

  // PRODUCTS
  const [iphone] = await sql`
    INSERT INTO products (name, sku, price)
    VALUES ('iPhone 15', 'APL-IP15', 999)
    RETURNING *
  `;

  const [samsung] = await sql`
    INSERT INTO products (name, sku, price)
    VALUES ('Samsung S24', 'SMS-S24', 899)
    RETURNING *
  `;

  // INVENTORY
  await sql`
    INSERT INTO inventory (store_id, product_id, quantity, min_stock)
    VALUES
      (${kyiv.id}, ${iphone.id}, 12, 5),
      (${kyiv.id}, ${samsung.id}, 3, 5),
      (${lviv.id}, ${iphone.id}, 2, 5)
  `;

  console.log("Seed completed 🚀");
}

seed();
