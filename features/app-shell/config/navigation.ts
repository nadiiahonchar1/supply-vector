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

export const navigation: NavigationItem[] = [
  {
    title: "Dashboard",
    href: "/",
    icon: Home,
  },
  {
    title: "Products",
    href: "/products",
    icon: Package,
  },
  {
    title: "Stores",
    href: "/stores",
    icon: Warehouse,
  },
  {
    title: "Inventory",
    href: "/inventory",
    icon: Boxes,
  },
  {
    title: "Shipments",
    href: "/shipments",
    icon: Truck,
  },
  {
    title: "Analytics",
    href: "/analytics",
    icon: BarChart3,
  },
  {
    title: "Users",
    href: "/users",
    icon: Users,
  },
];
