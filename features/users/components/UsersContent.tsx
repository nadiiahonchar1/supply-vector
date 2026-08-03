"use client";

import { useUsers } from "../api/hooks";
import { USERS_TEXT } from "../constants/users-text";
import { UsersGroups } from "./UsersGroups";

export function UsersContent() {
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

  return <UsersGroups users={data} />;
}
