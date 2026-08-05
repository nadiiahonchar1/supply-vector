"use client";

import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import {
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui";
import { USERS_TEXT } from "../constants/users-text";
import { ChangeRoleDialog, ChangeUserStatusDialog } from "./dialogs";

import type { User } from "../types";

type Props = {
  user: User;
};

export function UserActions({ user }: Props) {
  const [roleDialogOpen, setRoleDialogOpen] = useState(false);
  const [statusDialogOpen, setStatusDialogOpen] = useState(false);

  const openRoleDialog = () => {
    requestAnimationFrame(() => {
      setRoleDialogOpen(true);
    });
  };

  const openStatusDialog = () => {
    requestAnimationFrame(() => {
      setStatusDialogOpen(true);
    });
  };

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon">
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent align="end">
          <DropdownMenuItem onSelect={openRoleDialog}>
            {USERS_TEXT.actions.changeRole}
          </DropdownMenuItem>

          <DropdownMenuItem disabled>
            {USERS_TEXT.actions.assignStores}

            <span className="ml-auto rounded bg-muted px-2 py-0.5 text-[10px] font-medium uppercase text-muted-foreground">
              {USERS_TEXT.actions.comingSoon}
            </span>
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem onSelect={openStatusDialog}>
            {user.is_active
              ? USERS_TEXT.actions.deactivate
              : USERS_TEXT.actions.activate}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      <ChangeRoleDialog
        user={user}
        open={roleDialogOpen}
        onOpenChange={setRoleDialogOpen}
      />

      <ChangeUserStatusDialog
        user={user}
        open={statusDialogOpen}
        onOpenChange={setStatusDialogOpen}
      />
    </>
  );
}
