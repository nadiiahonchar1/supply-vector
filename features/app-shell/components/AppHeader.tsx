"use client";

import { PanelLeft } from "lucide-react";

import { Button } from "@/components/ui/button";

import { SidebarInset, SidebarTrigger } from "@/components/ui/sidebar";

export function AppHeader({ children }: { children: React.ReactNode }) {
  return (
    <SidebarInset>
      <header className="flex h-16 items-center justify-between border-b bg-background px-6">
        <div className="flex items-center gap-3">
          <SidebarTrigger asChild>
            <Button variant="ghost" size="icon">
              <PanelLeft className="size-5" />
            </Button>
          </SidebarTrigger>

          <h1 className="text-lg font-semibold">Dashboard</h1>
        </div>

        <div className="flex items-center gap-3">{/* UserMenu */}</div>
      </header>

      <main className="flex-1 p-6">{children}</main>
    </SidebarInset>
  );
}
