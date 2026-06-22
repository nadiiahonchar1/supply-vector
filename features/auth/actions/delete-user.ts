"use server";

import { sql } from "@/db";

import { requireUser } from "@/lib/auth/auth-service";
import { canManageRole, getHighestRole } from "@/lib/auth/permissions";
import { Role } from "@/lib/auth/permissions";

type DeleteUserInput = {
  userId: string;
};

export async function deleteUserAction({ userId }: DeleteUserInput) {
  const currentUser = await requireUser();

  if (currentUser.id === userId) {
    throw new Error("You cannot delete yourself");
  }

  const currentRoles = currentUser.roles;
  const currentRole = getHighestRole(currentRoles);

  const targetRolesRows = await sql`
    SELECT r.code
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = ${userId}
  `;

  const targetRoles = targetRolesRows.map((r) => r.code as Role);

  if (!targetRoles.length) {
    throw new Error("Target user role not found");
  }

  const targetRole = getHighestRole(targetRoles);

  if (!canManageRole(currentRole, targetRole)) {
    throw new Error("Forbidden");
  }

  const result = await sql`
    UPDATE users
    SET
      is_active = false,
      deleted_at = NOW(),
      deleted_by = ${currentUser.id},
      updated_at = NOW()
    WHERE id = ${userId}
      AND is_active = true
    RETURNING id
  `;

  if (!result.length) {
    throw new Error("User not found");
  }

  return { success: true };
}
