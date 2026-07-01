"use server";

import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";
import type { DeleteUserInput } from "@/features/users/type";

export async function deleteUserAction({ userId }: DeleteUserInput) {
  const currentUser = await requireUser();

  await UserManagementService.deleteUser(currentUser, userId);

  await AuditService.log({
    userId: currentUser.id,
    action: "user:delete",
    entity: "users",
    entityId: userId,
  });

  return { success: true };
}
