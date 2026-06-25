"use server";

import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";
import { Role } from "@/lib/auth/permissions";

type CreateUserInput = {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  role: Role;
  storeIds?: string[];
};

export async function createUserAction(input: CreateUserInput) {
  const currentUser = await requireUser();

  const result = await UserManagementService.createUser(currentUser.id, input);

  await AuditService.log({
    userId: currentUser.id,
    action: "user:create",
    entity: "users",
    entityId: result.userId,
    meta: {
      email: input.email,
      role: input.role,
    },
  });

  return { success: true, userId: result.userId };
}
