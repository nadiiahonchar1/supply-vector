export type Role = "super_admin" | "admin" | "manager" | "operator" | "viewer";

const roleHierarchy: Record<Role, number> = {
  super_admin: 5,
  admin: 4,
  manager: 3,
  operator: 2,
  viewer: 1,
};
