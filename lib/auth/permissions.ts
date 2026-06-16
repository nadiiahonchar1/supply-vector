export const ROLES = {
  SUPER_ADMIN: "superadmin",
  ADMIN: "admin",
  MANAGER: "manager",
  VIEWER: "viewer",
} as const;

export type Role = (typeof ROLES)[keyof typeof ROLES];

export const roleHierarchy: Record<Role, number> = {
  superadmin: 5,
  admin: 4,
  manager: 3,
  viewer: 1,
};
