import { cache } from "react";
import { sql } from "@/db";
import { getSessionFromCookie } from "./session";
import type { CurrentUser } from "@/features/auth/types";

export const getCurrentUser = cache(async (): Promise<CurrentUser | null> => {
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
});
