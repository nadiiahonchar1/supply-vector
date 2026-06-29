import { Role, canManageRole } from "@/lib/auth/permissions";

export type AuthUser = {
  id: string;
  role: Role;
};

export class UserPolicy {
  static canCreate(current: AuthUser, targetRole: Role) {
    return canManageRole(current.role, targetRole);
  }

  static canDelete(
    current: AuthUser,
    targetUser: {
      id: string;
      role: Role;
    },
  ) {
    if (current.id === targetUser.id) {
      return false;
    }

    return canManageRole(current.role, targetUser.role);
  }

  static canChangePassword(current: AuthUser, targetUserId: string) {
    return current.id === targetUserId;
  }
}