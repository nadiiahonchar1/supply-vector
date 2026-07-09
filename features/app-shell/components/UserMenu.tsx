"use client";

import { LogOut, User } from "lucide-react";

import { useAuth } from "@/features/auth/context/useAuth";
import { useLogout } from "@/features/auth/hooks/useLogout";
import { getUserInitials } from "@/features/auth/utils/user";
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

  //   const initials = `${user.first_name[0] ?? ""}${user.last_name[0] ?? ""}`;
  const initials = getUserInitials(user);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button className="flex items-center gap-3 rounded-md px-2 py-1 hover:bg-accent transition-colors">
          <Avatar className="size-9">
            <AvatarFallback>{initials}</AvatarFallback>
          </Avatar>

          <div className="text-left">
            <div className="text-sm font-medium">
              {user.first_name} {user.last_name}
            </div>

            <div className="text-xs text-muted-foreground">{user.role}</div>
          </div>
        </button>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuLabel>{user.email}</DropdownMenuLabel>

        <DropdownMenuSeparator />

        <DropdownMenuItem>
          <User className="mr-2 size-4" />
          Profile
        </DropdownMenuItem>

        <DropdownMenuSeparator />

        <DropdownMenuItem onClick={logout}>
          <LogOut className="mr-2 size-4" />
          Logout
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
