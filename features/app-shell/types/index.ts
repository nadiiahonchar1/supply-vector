import type { LucideIcon } from "lucide-react";

import type { Permission } from "@/features/auth";

export type NavigationItem = {
  title: string;
  href: string;
  icon: LucideIcon;
  permission?: Permission;
};
