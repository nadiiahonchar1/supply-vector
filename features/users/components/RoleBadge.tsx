import { Badge } from "@/components/ui";
import type { Role } from "@/features/auth";
import { USERS_TEXT } from "../constants/users-text";

type Props = {
  role: Role;
};

const roleVariant: Record<
  Role,
  "default" | "secondary" | "destructive" | "outline"
> = {
  superadmin: "destructive",
  admin: "default",
  manager: "secondary",
  operator: "outline",
};

const roleLabel: Record<Role, string> = {
  superadmin: USERS_TEXT.role.superadmin,
  admin: USERS_TEXT.role.admin,
  manager: USERS_TEXT.role.manager,
  operator: USERS_TEXT.role.operator,
};

export function RoleBadge({ role }: Props) {
  return <Badge variant={roleVariant[role]}>{roleLabel[role]}</Badge>;
}
