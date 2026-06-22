import { sql } from "@/db";
import { getSessionFromCookie } from "./session";

export type CurrentUser = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
};

export async function getCurrentUser(): Promise<CurrentUser | null> {
  const session = await getSessionFromCookie();

  if (!session) return null;

  const users = (await sql`
    SELECT
      id,
      email,
      first_name,
      last_name,
      is_active
    FROM users
    WHERE id = ${session.user_id}
      AND is_active = true
    LIMIT 1
  `) as CurrentUser[];

  return users[0] || null;
}
