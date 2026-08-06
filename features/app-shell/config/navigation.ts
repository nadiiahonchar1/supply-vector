import {
  BarChart3,
  Boxes,
  Home,
  Package,
  Truck,
  Users,
  Warehouse,
} from "lucide-react";
import type { NavigationItem } from "../types";
import { APP_SHELL_TEXT } from "../constants/app-shell-text";

export const navigation: NavigationItem[] = [
  {
    title: APP_SHELL_TEXT.navigation.home,
    href: "/",
    icon: Home,
  },
  {
    title: APP_SHELL_TEXT.navigation.products,
    href: "/products",
    icon: Package,
  },
  {
    title: APP_SHELL_TEXT.navigation.stores,
    href: "/stores",
    icon: Warehouse,
  },
  {
    title: APP_SHELL_TEXT.navigation.inventory,
    href: "/inventory",
    icon: Boxes,
  },
  {
    title: APP_SHELL_TEXT.navigation.shipments,
    href: "/shipments",
    icon: Truck,
  },
  {
    title: APP_SHELL_TEXT.navigation.analitics,
    href: "/analytics",
    icon: BarChart3,
  },
  {
    title: APP_SHELL_TEXT.navigation.users,
    href: "/users",
    icon: Users,
  },
];
