import type { Role } from "@/features/auth";

export const ROLE_LABELS: Record<Role, string> = {
  superadmin: "Суперадміністратор",
  admin: "Адміністратор",
  manager: "Менеджер",
  operator: "Оператор",
};

export function getRoleLabel(role: Role): string {
  return ROLE_LABELS[role];
}
