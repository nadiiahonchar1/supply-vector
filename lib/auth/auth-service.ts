import { sql } from "@/db";

import { verifyPassword } from "./password";
import { createSession, deleteSession } from "./session";
import { getCurrentUser } from "./get-current-user";
import { Role, rolePermissions, Permission } from "./permissions";

// =====================================
// LOGIN
// =====================================
export async function loginUser(email: string, password: string) {
  const users = await sql`
    SELECT
      id,
      email,
      password_hash,
      is_active
    FROM users
    WHERE email = ${email}
    LIMIT 1
  `;

  const user = users[0];

  if (!user || !user.is_active) {
    throw new Error("Invalid credentials");
  }

  const isValid = await verifyPassword(password, user.password_hash);

  if (!isValid) {
    throw new Error("Invalid credentials");
  }

  await sql`
    UPDATE users
    SET last_login_at = NOW()
    WHERE id = ${user.id}
  `;

  const sessionToken = await createSession(user.id);

  return {
    userId: user.id,
    email: user.email,
    sessionToken,
  };
}

// =====================================
// LOGOUT
// =====================================
export async function logoutUser(token: string) {
  await deleteSession(token);
}

// =====================================
// CURRENT USER (SAFE WRAPPER)
// =====================================
export async function requireUser() {
  const user = await getCurrentUser();

  if (!user) {
    throw new Error("Unauthorized");
  }

  return user;
}

// =====================================
// ROLE CHECK
// =====================================
export function hasRole(userRole: Role, role: Role) {
  return userRole === role;
}

// =====================================
// PERMISSION CHECK
// =====================================
export function checkPermission(role: Role, permission: Permission): boolean {
  return rolePermissions[role]?.includes(permission) ?? false;
}

// =====================================
// STRICT GUARD (THROW IF NO ACCESS)
// =====================================
export function requirePermission(role: Role, permission: Permission) {
  const allowed = checkPermission(role, permission);

  if (!allowed) {
    throw new Error("Forbidden");
  }
}
