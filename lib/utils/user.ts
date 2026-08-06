import type { CurrentUser } from "../../features/auth/types";

export function getUserFullName(user: CurrentUser) {
  return `${user.first_name} ${user.last_name}`;
}

export function getUserInitials(user: CurrentUser) {
  return `${user.first_name[0] ?? ""}${user.last_name[0] ?? ""}`;
}
