// import "dotenv/config";
import { sql } from "./index";

async function check() {
  const tables = await sql`
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public';
  `;

    console.log(tables);
}

check();
