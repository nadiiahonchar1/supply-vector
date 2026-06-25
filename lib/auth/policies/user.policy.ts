import { Role } from "@/lib/auth/permissions";
import { getHighestRole, canManageRole } from "@/lib/auth/permissions";

export type AuthUser = {
  id: string;
  roles: Role[];
};

export class UserPolicy {
  static canCreate(current: AuthUser, targetRole: Role) {
    const currentRole = getHighestRole(current.roles);
    return canManageRole(currentRole, targetRole);
  }

  static canDelete(
    current: AuthUser,
    targetUser: { id: string; roles: Role[] },
  ) {
    const currentRole = getHighestRole(current.roles);
    const targetRole = getHighestRole(targetUser.roles);

    // self delete protection
    if (current.id === targetUser.id) return false;

    return canManageRole(currentRole, targetRole);
  }

  static canChangePassword(current: AuthUser, targetUserId: string) {
    return current.id === targetUserId;
  }
}
