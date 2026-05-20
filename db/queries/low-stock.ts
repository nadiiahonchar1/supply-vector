import { sql } from "../index";

async function lowStock() {
  const result = await sql`
    SELECT
      s.name AS store,
      p.name AS product,
      i.quantity,
      i.min_stock
    FROM inventory i
    JOIN stores s ON s.id = i.store_id
    JOIN products p ON p.id = i.product_id
    WHERE i.quantity < i.min_stock;
  `;

  console.log(result);
}

lowStock();
