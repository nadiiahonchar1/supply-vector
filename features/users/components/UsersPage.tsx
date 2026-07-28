"use client";

import { Button } from "@/components/ui/button";
import { UsersTable } from "../components";
import { USERS_TEXT } from "../constants/users-text";

export function UsersPage() {
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">{USERS_TEXT.title}</h1>

          <p className="text-muted-foreground">{USERS_TEXT.subtitle}</p>
        </div>

        <Button>{USERS_TEXT.create}</Button>
      </div>

      <UsersTable />
    </div>
  );
}
