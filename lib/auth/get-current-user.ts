import { sql } from "@/db";

import { Role } from "./permissions";
import { getSessionFromCookie } from "./session";

export type CurrentUser = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
  role: Role;
};

export async function getCurrentUser(): Promise<CurrentUser | null> {
  const session = await getSessionFromCookie();

  if (!session) return null;

  const users = (await sql`
    SELECT
      u.id,
      u.email,
      u.first_name,
      u.last_name,
      u.is_active,
      r.code AS role
    FROM users u
    JOIN user_roles ur
      ON ur.user_id = u.id
    JOIN roles r
      ON r.id = ur.role_id
    WHERE u.id = ${session.user_id}
      AND u.is_active = true
    LIMIT 1
  `) as CurrentUser[];

  return users[0] ?? null;
}
