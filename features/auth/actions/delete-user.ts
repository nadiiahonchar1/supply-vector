"use server";

import { sql } from "@/db";

import { requireUser } from "@/lib/auth/auth-service";
import { canManageRole } from "@/lib/auth/permissions";

import { getUserRoleQuery } from "../queries/get-user-role-query";

type DeleteUserInput = {
  userId: string;
};

export async function deleteUserAction({ userId }: DeleteUserInput) {
  const currentUser = await requireUser();

  if (currentUser.id === userId) {
    throw new Error("You cannot delete yourself");
  }

  const currentRole = await getUserRoleQuery(currentUser.id);

  if (!currentRole) {
    throw new Error("Current user role not found");
  }

  const targetRole = await getUserRoleQuery(userId);

  if (!targetRole) {
    throw new Error("Target user role not found");
  }

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

  return {
    success: true,
  };
}
