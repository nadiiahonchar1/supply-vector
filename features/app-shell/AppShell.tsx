"use client";

import { usePathname } from "next/navigation";

import { SidebarInset, SidebarProvider } from "@/components/ui";
import { AppHeader, AppSidebar } from "@/features/app-shell";

type AppShellProps = {
  children: React.ReactNode;
};

export function AppShell({ children }: AppShellProps) {
  const pathname = usePathname();

  const isPublicPage = pathname.startsWith("/login");

  if (isPublicPage) {
    return children;
  }

  return (
    <SidebarProvider>
      <AppSidebar />

      <SidebarInset>
        <AppHeader />

        <main className="flex flex-1 flex-col p-6">{children}</main>
      </SidebarInset>
    </SidebarProvider>
  );
}
