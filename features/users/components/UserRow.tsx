import { TableCell, TableRow } from "@/components/ui/table";

import type { User } from "../types";

import { RoleBadge } from "./RoleBadge";

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

      <TableCell>{user.is_active ? "Active" : "Inactive"}</TableCell>

      <TableCell>Actions</TableCell>
    </TableRow>
  );
}
