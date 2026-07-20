import type { Role } from "../types";

export const ROLE_LABELS: Record<Role, string> = {
  superadmin: "Суперадміністратор",
  admin: "Адміністратор",
  manager: "Менеджер",
  viewer: "Оператор",
};

export function getRoleLabel(role: Role): string {
  return ROLE_LABELS[role];
}
