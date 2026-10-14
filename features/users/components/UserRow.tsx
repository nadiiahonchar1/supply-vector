import { TableCell, TableRow } from "@/components/ui";
import { RoleBadge, UserActions, UserStatusBadge } from "@/features/users";

import type { User } from "@/features/users";

type Props = {
  user: User;
};

export function UserRow({ user }: Props) {
  return (
    <TableRow>
      <TableCell>{user.first_name}</TableCell>

      <TableCell>{user.last_name}</TableCell>

      <TableCell>{user.email}</TableCell>

      <TableCell>
        <RoleBadge role={user.role} />
      </TableCell>

      <TableCell>
        <UserStatusBadge isActive={user.is_active} />
      </TableCell>

      <TableCell className="w-[64px] text-right">
        <UserActions user={user} />
      </TableCell>
    </TableRow>
  );
}
