"use client";

import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

import type { User } from "../types";

import { USERS_TEXT } from "../constants/users-text";
import { UserRow } from "./UserRow";

type Props = {
  users: User[];
};

export function UsersTable({ users }: Props) {
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

      <TableBody>
        {users.map((user) => (
          <UserRow key={user.id} user={user} />
        ))}
      </TableBody>
    </Table>
  );
}
