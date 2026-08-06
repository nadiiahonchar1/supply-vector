"use client";

import Link from "next/link";
import { LogOut, User } from "lucide-react";
import { useAuth, useLogout, getRoleLabel } from "@/features/auth";
import { getUserFullName, getUserInitials } from "@/lib/utils";
import {
  Avatar,
  AvatarFallback,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui";
import { APP_SHELL_TEXT } from "../constants/app-shell-text";

export function UserMenu() {
  const { user } = useAuth();
  const { logout } = useLogout();

  if (!user) {
    return null;
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button className="flex items-center gap-3 rounded-md px-2 py-1 transition-colors hover:bg-accent">
          <Avatar className="size-9">
            <AvatarFallback>{getUserInitials(user)}</AvatarFallback>
          </Avatar>

          <div className="text-left">
            <div className="text-sm font-medium">{getUserFullName(user)}</div>

            <div className="text-xs text-muted-foreground">
              {getRoleLabel(user.role)}
            </div>
          </div>
        </button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuLabel>{user.email}</DropdownMenuLabel>

        <DropdownMenuSeparator />

        <DropdownMenuItem asChild>
          <Link href="/profile">
            <User className="mr-2 size-4" />
            {APP_SHELL_TEXT.user_menu.profile}
          </Link>
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem onClick={logout}>
          <LogOut className="mr-2 size-4" />
          {APP_SHELL_TEXT.user_menu.logout}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
