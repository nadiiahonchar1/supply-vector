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

export function UsersTable() {
  const { data, isLoading, error } = useUsers();

  if (isLoading) {
    return <div>Loading users...</div>;
  }

  if (error) {
    return <div>Failed to load users.</div>;
  }

  if (!data?.length) {
    return <div>No users found.</div>;
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>First name</TableHead>

          <TableHead>Last name</TableHead>

          <TableHead>Email</TableHead>

          <TableHead>Role</TableHead>

          <TableHead>Status</TableHead>

          <TableHead className="w-[160px]">Actions</TableHead>
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
