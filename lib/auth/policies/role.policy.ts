import { Role } from "@/lib/auth/permissions";
import { getHighestRole, canManageRole } from "@/lib/auth/permissions";

export type AuthUser = {
  id: string;
  roles: Role[];
};

export class RolePolicy {
  static canAssignRole(current: AuthUser, targetRole: Role) {
    const currentRole = getHighestRole(current.roles);
    return canManageRole(currentRole, targetRole);
  }

  static canChangeUserRole(
    current: AuthUser,
    currentUserRole: Role,
    targetRole: Role,
  ) {
    const actorRole = getHighestRole(current.roles);

    if (!canManageRole(actorRole, targetRole)) {
      return false;
    }

    if (!canManageRole(actorRole, currentUserRole)) {
      return false;
    }

    return true;
  }

  static canDeleteRole(current: AuthUser) {
    const role = getHighestRole(current.roles);

    return role === "superadmin";
  }
}
