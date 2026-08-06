"use client";

import { SidebarTrigger } from "@/components/ui";
import { UserMenu } from "./UserMenu";
import { APP_SHELL_TEXT } from "../constants/app-shell-text";

export function AppHeader() {
  return (
    <header className="flex h-16 items-center justify-between border-b bg-background px-6">
      <div className="flex items-center gap-3">
        <SidebarTrigger />

        <h1 className="text-lg font-semibold">{APP_SHELL_TEXT.title}</h1>
      </div>

      <UserMenu />
    </header>
  );
}
