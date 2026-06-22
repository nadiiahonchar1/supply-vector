"use server";

import { sql } from "@/db";

import { requireUser } from "@/lib/auth/auth-service";
import { hashPassword } from "@/lib/auth/password";
import { canManageRole, Role, getHighestRole } from "@/lib/auth/permissions";

type CreateUserInput = {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  role: Role;
  storeIds?: string[];
};

export async function createUserAction({
  email,
  password,
  firstName,
  lastName,
  role,
  storeIds = [],
}: CreateUserInput) {
  const currentUser = await requireUser();

  const currentRole = getHighestRole(currentUser.roles);

  if (!canManageRole(currentRole, role)) {
    throw new Error("Forbidden");
  }

  const existingUsers = await sql`
    SELECT id FROM users WHERE email = ${email} LIMIT 1
  `;

  if (existingUsers.length) {
    throw new Error("User with this email already exists");
  }

  const passwordHash = await hashPassword(password);

  const users = await sql`
    INSERT INTO users (
      email,
      password_hash,
      first_name,
      last_name,
      is_active,
      created_by
    )
    VALUES (
      ${email},
      ${passwordHash},
      ${firstName},
      ${lastName},
      true,
      ${currentUser.id}
    )
    RETURNING id
  `;

  const userId = users[0].id;

  const roles = await sql`
    SELECT id FROM roles WHERE code = ${role} LIMIT 1
  `;

  const roleId = roles[0]?.id;

  if (!roleId) {
    throw new Error("Role not found");
  }

  await sql`
    INSERT INTO user_roles (user_id, role_id)
    VALUES (${userId}, ${roleId})
  `;

  if (storeIds.length) {
    for (const storeId of storeIds) {
      await sql`
        INSERT INTO user_stores (user_id, store_id)
        VALUES (${userId}, ${storeId})
      `;
    }
  }

  return { userId };
}
