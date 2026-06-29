import { Role, canManageRole, roleHierarchy } from "@/lib/auth/permissions";

export class UserPolicy {
  static canViewUsers(role: Role) {
    return roleHierarchy[role] >= roleHierarchy.manager;
  }

  static canCreateUser(role: Role) {
    return roleHierarchy[role] >= roleHierarchy.admin;
  }

  static canDeleteUser(role: Role, targetRole: Role) {
    return canManageRole(role, targetRole);
  }

  static canChangePassword(userId: string, targetUserId: string) {
    return userId === targetUserId;
  }
}
