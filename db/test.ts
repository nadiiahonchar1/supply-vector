import { sql } from "./index";

async function test() {
  const result = await sql`
    SELECT NOW()
  `;

  console.log(result);
}

test();
