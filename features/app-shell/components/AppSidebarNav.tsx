"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navigation } from "../config/navigation";
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui";

export function AppSidebarNav() {
  const pathname = usePathname();

  return (
    <SidebarMenu>
      {navigation.map((item) => {
        const Icon = item.icon;

        const isActive =
          item.href === "/" ? pathname === "/" : pathname.startsWith(item.href);

        return (
          <SidebarMenuItem key={item.href}>
            <SidebarMenuButton asChild isActive={isActive}>
              <Link href={item.href}>
                <Icon className="size-4" />

                <span>{item.title}</span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        );
      })}
    </SidebarMenu>
  );
}
