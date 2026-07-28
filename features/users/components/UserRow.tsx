import { TableCell, TableRow } from "@/components/ui/table";

import type { User } from "../types";

import { RoleBadge } from "./RoleBadge";
import { UserActions } from "./UserActions";
import { UserStatusBadge } from "./UserStatusBadge";

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
