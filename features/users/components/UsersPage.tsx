"use client";

import { useState } from "react";

import { Button } from "@/components/ui/button";

import { UsersTable } from "../components";
import { CreateUserDialog } from "../components/dialogs/CreateUserDialog";
import { USERS_TEXT } from "../constants/users-text";

export function UsersPage() {
  const [open, setOpen] = useState(false);

  return (
    <>
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-semibold">{USERS_TEXT.title}</h1>

            <p className="text-muted-foreground">{USERS_TEXT.subtitle}</p>
          </div>

          <Button onClick={() => setOpen(true)}>{USERS_TEXT.create}</Button>
        </div>

        <UsersTable />
      </div>

      <CreateUserDialog open={open} onOpenChange={setOpen} />
    </>
  );
}
