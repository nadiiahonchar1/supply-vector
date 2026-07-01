import type { Role, AuthUser } from "@/features/auth/types";
import { canManageRole } from "../permissions";

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
