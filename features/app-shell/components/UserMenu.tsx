"use client";

import Link from "next/link";
import { LogOut, User } from "lucide-react";

import { useAuth } from "@/features/auth/context/useAuth";
import { useLogout } from "@/features/auth/hooks/useLogout";
import { getUserFullName, getUserInitials } from "@/features/auth/utils/user";
import { getRoleLabel } from "@/features/auth/constants/role-labels";

import { Avatar, AvatarFallback } from "@/components/ui/avatar";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

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
            Профіль
          </Link>
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem onClick={logout}>
          <LogOut className="mr-2 size-4" />
          Вийти
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
