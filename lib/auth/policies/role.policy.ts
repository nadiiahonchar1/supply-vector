import { Role } from "@/lib/auth/permissions";
import { getHighestRole, canManageRole } from "@/lib/auth/permissions";

export type AuthUser = {
  id: string;
  roles: Role[];
};

export class RolePolicy {
  static canAssignRole(current: AuthUser, targetRole: Role) {
    const actorRole = getHighestRole(current.roles);
    return canManageRole(actorRole, targetRole);
  }

  static canChangeUserRole(
    current: AuthUser,
    currentUserRole: Role,
    targetRole: Role,
  ) {
    const actorRole = getHighestRole(current.roles);

    return (
      canManageRole(actorRole, currentUserRole) &&
      canManageRole(actorRole, targetRole)
    );
  }

  static canDeleteUser(current: AuthUser, targetRole: Role) {
    const actorRole = getHighestRole(current.roles);

    return canManageRole(actorRole, targetRole);
  }
}
