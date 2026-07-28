"use client";

import { MoreHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { USERS_TEXT } from "../constants/users-text";

import type { User } from "../types";

type Props = {
  user: User;
};

export function UserActions({ user }: Props) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon">
          <MoreHorizontal className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end">
        <DropdownMenuItem>{USERS_TEXT.actions.changeRole}</DropdownMenuItem>

        <DropdownMenuItem>{USERS_TEXT.actions.assignStores}</DropdownMenuItem>

        <DropdownMenuSeparator />

        {user.is_active ? (
          <DropdownMenuItem>{USERS_TEXT.actions.deactivate}</DropdownMenuItem>
        ) : (
          <DropdownMenuItem>{USERS_TEXT.actions.activate}</DropdownMenuItem>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
