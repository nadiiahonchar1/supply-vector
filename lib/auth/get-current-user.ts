import { sql } from "@/db";
import { getSessionFromCookie } from "./session";


export async function getCurrentUser() {
  const session = await getSessionFromCookie();

  if (!session) return null;

  const users = await sql`
    SELECT
      id,
      email,
      first_name,
      last_name,
      is_active
    FROM users
    WHERE id = ${session.user_id}
      AND is_active = true
  `;

  return users[0] || null;
}
