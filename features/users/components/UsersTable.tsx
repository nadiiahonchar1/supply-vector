"use client";

import type { ReactNode } from "react";

import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

import { USERS_TEXT } from "../constants/users-text";

import type { User } from "../types";

import { GroupHeaderRow } from "./UsersTable/GroupHeaderRow";
import { UserRow } from "./UserRow";

type Props = {
  users: User[];
};

export function UsersTable({ users }: Props) {
  const roleTitles: Record<User["role"], string> = {
    superadmin: USERS_TEXT.role.superadmin,
    admin: USERS_TEXT.role.admin,
    manager: USERS_TEXT.role.manager,
    operator: USERS_TEXT.role.operator,
  };

  const roleCounts = users.reduce(
    (acc, user) => {
      acc[user.role] = (acc[user.role] ?? 0) + 1;

      return acc;
    },
    {} as Record<User["role"], number>,
  );

  const tableRows: ReactNode[] = [];

  let previousRole: User["role"] | null = null;

  for (const user of users) {
    if (user.role !== previousRole) {
      tableRows.push(
        <GroupHeaderRow
          key={`group-${user.role}`}
          title={roleTitles[user.role]}
          count={roleCounts[user.role]}
        />,
      );

      previousRole = user.role;
    }

    tableRows.push(<UserRow key={user.id} user={user} />);
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>{USERS_TEXT.table.firstName}</TableHead>

          <TableHead>{USERS_TEXT.table.lastName}</TableHead>

          <TableHead>{USERS_TEXT.table.email}</TableHead>

          <TableHead>{USERS_TEXT.table.role}</TableHead>

          <TableHead>{USERS_TEXT.table.status}</TableHead>

          <TableHead className="w-[160px]">
            {USERS_TEXT.table.actions}
          </TableHead>
        </TableRow>
      </TableHeader>

      <TableBody>{tableRows}</TableBody>
    </Table>
  );
}
