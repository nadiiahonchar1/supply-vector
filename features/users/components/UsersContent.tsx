"use client";

import { useState } from "react";
import { useUsers } from "../api";
import { USERS_TEXT } from "../constants/users-text";
import { UsersTable, PaginationBar } from "../components";

export function UsersContent() {
  const [page, setPage] = useState(1);

  const { data, isLoading, error } = useUsers(page);

  if (isLoading) {
    return <div>{USERS_TEXT.loading}</div>;
  }

  if (error) {
    return <div>{USERS_TEXT.error.loading}</div>;
  }

  if (!data || !data.users.length) {
    return <div>{USERS_TEXT.error.empty_user}</div>;
  }

  return (
    <>
      <UsersTable users={data.users} />
      <PaginationBar
        page={page}
        totalPages={data.totalPages}
        onPageChange={setPage}
      />
    </>
  );
}
