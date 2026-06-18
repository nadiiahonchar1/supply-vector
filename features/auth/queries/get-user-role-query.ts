import { sql } from "@/db";
import { Role } from "@/lib/auth/permissions";

export async function getUserRoleQuery(userId: string): Promise<Role | null> {
  const rows = await sql`
    SELECT r.code
    FROM user_roles ur
    JOIN roles r
      ON r.id = ur.role_id
    WHERE ur.user_id = ${userId}
    LIMIT 1
  `;

  return (rows[0]?.code as Role) ?? null;
}
