"use client";

import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useUsers } from "../api/hooks";
import { UserRow } from "./UserRow";
import { USERS_TEXT } from "../constants/users-text";

export function UsersTable() {
  const { data, isLoading, error } = useUsers();

  if (isLoading) {
    return <div>{USERS_TEXT.loading}</div>;
  }

  if (error) {
    return <div>{USERS_TEXT.error}</div>;
  }

  if (!data?.length) {
    return <div>{USERS_TEXT.empty}</div>;
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

      <TableBody>
        {data.map((user) => (
          <UserRow key={user.id} user={user} />
        ))}
      </TableBody>
    </Table>
  );
}
