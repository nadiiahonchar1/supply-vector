import type { LucideIcon } from "lucide-react";

import type { Permission } from "@/features/auth/types";

export type NavigationItem = {
  title: string;
  href: string;
  icon: LucideIcon;
  permission?: Permission;
};
