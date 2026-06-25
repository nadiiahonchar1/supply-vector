import { sql } from "@/db";
import { getSessionFromCookie } from "./session";
import { Role } from "./permissions";

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

  const rows = await sql`
    SELECT
      u.id,
      u.email,
      u.first_name,
      u.last_name,
      u.is_active,
      r.code AS role
    FROM users u
    JOIN user_roles ur ON ur.user_id = u.id
    JOIN roles r ON r.id = ur.role_id
    WHERE u.id = ${session.user_id}
      AND u.is_active = true
    LIMIT 1
  `;

  const user = rows[0];

  if (!user) return null;

  return {
    id: user.id,
    email: user.email,
    first_name: user.first_name,
    last_name: user.last_name,
    is_active: user.is_active,
    role: user.role as Role,
  };
}
