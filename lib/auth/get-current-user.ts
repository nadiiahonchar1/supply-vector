import { cookies } from "next/headers";
import { sql } from "@/db";

export async function getCurrentUser() {
  const cookieStore = await cookies();
  const userId = cookieStore.get("session")?.value;

  if (!userId) return null;

  const users = await sql`
    SELECT
      id,
      email,
      first_name,
      last_name,
      is_active
    FROM users
    WHERE id = ${userId}
      AND is_active = true
  `;

  return users[0] || null;
}
