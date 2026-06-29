import { Role } from "@/lib/auth/permissions";
import { canManageRole } from "@/lib/auth/permissions";

export type AuthUser = {
  id: string;
  role: Role;
};

export class RolePolicy {
  static canAssignRole(current: AuthUser, targetRole: Role) {
    return canManageRole(current.role, targetRole);
  }

  static canChangeUserRole(
    current: AuthUser,
    currentUserRole: Role,
    targetRole: Role,
  ) {
    return (
      canManageRole(current.role, currentUserRole) &&
      canManageRole(current.role, targetRole)
    );
  }
}
