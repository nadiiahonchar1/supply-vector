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
        <DropdownMenuItem>Change role</DropdownMenuItem>

        <DropdownMenuItem>Edit stores</DropdownMenuItem>

        <DropdownMenuSeparator />

        {user.is_active ? (
          <DropdownMenuItem>Deactivate</DropdownMenuItem>
        ) : (
          <DropdownMenuItem>Activate</DropdownMenuItem>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
