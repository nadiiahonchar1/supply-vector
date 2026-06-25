"use server";

import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";

type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};

export async function changePasswordAction(input: ChangePasswordInput) {
  const currentUser = await requireUser();

  await UserManagementService.changePassword(currentUser, input);

  await AuditService.log({
    userId: currentUser.id,
    action: "password:change",
    entity: "users",
    entityId: currentUser.id,
  });

  return { success: true };
}
