import { Badge } from "@/components/ui/badge";

import type { Role } from "@/features/auth";

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
  superadmin: "Super Admin",
  admin: "Admin",
  manager: "Manager",
  operator: "Operator",
};

export function RoleBadge({ role }: Props) {
  return <Badge variant={roleVariant[role]}>{roleLabel[role]}</Badge>;
}
