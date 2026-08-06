"use client";

import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarRail,
} from "@/components/ui";
import { APP_NAME } from "../config/app";
import { AppSidebarNav } from "./AppSidebarNav";
import { APP_SHELL_TEXT } from "../constants/app-shell-text";

export function AppSidebar() {
  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="border-b">
        <div className="flex h-14 items-center px-4">
          <span className="text-lg font-semibold">{APP_NAME}</span>
        </div>
      </SidebarHeader>

      <SidebarContent>
        <AppSidebarNav />
      </SidebarContent>

      <SidebarFooter className="border-t">
        <div className="p-4 text-xs text-muted-foreground">
          {APP_SHELL_TEXT.footer}
        </div>
      </SidebarFooter>

      <SidebarRail />
    </Sidebar>
  );
}
