"use client";

import { SidebarTrigger } from "@/components/ui/sidebar";

import { UserMenu } from "./UserMenu";

export function AppHeader() {
  return (
    <header className="flex h-16 items-center justify-between border-b bg-background px-6">
      <div className="flex items-center gap-3">
        <SidebarTrigger />

        <h1 className="text-lg font-semibold">Dashboard</h1>
      </div>

      <UserMenu />
    </header>
  );
}
