"use client";

import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { USERS_TEXT } from "../constants/users-text";
import { ChangeRoleDialog } from "./dialogs";

import type { User } from "../types";

type Props = {
  user: User;
};

export function UserActions({ user }: Props) {
  const [roleDialogOpen, setRoleDialogOpen] = useState(false);
  const [statusDialogOpen, setStatusDialogOpen] = useState(false);
  const [storesDialogOpen, setStoresDialogOpen] = useState(false);

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon">
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent align="end">
          <DropdownMenuItem
            onSelect={(e) => {
              e.preventDefault();
              setRoleDialogOpen(true);
            }}
          >
            {USERS_TEXT.actions.changeRole}
          </DropdownMenuItem>

          <DropdownMenuItem
            onSelect={(e) => {
              e.preventDefault();
            }}
          >
            {USERS_TEXT.actions.assignStores}
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem
            onSelect={(e) => {
              e.preventDefault();
              setStatusDialogOpen(true);
            }}
          >
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

      <AssignStoresDialog
        user={user}
        open={storesDialogOpen}
        onOpenChange={setStoresDialogOpen}
      />
    </>
  );
}
