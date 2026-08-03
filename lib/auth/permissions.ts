import type { Role, Permission } from "@/features/auth";

export const ROLES = {
  SUPER_ADMIN: "superadmin",
  ADMIN: "admin",
  MANAGER: "manager",
  OPERATOR: "operator",
} as const;

// =====================================
// ROLE HIERARCHY
// =====================================

export const roleHierarchy: Record<Role, number> = {
  superadmin: 4,
  admin: 3,
  manager: 2,
  operator: 1,
};

// =====================================
// PERMISSIONS
// =====================================

export const PERMISSIONS = {
  // USERS
  USER_VIEW: "user:view",

  // INVENTORY
  INVENTORY_VIEW: "inventory:view",
  INVENTORY_ADJUST: "inventory:adjust",

  // PRODUCTS
  PRODUCT_CREATE: "product:create",
  PRODUCT_UPDATE: "product:update",

  // SHIPMENTS
  SHIPMENT_CREATE: "shipment:create",
  SHIPMENT_UPDATE: "shipment:update",
  SHIPMENT_CANCEL: "shipment:cancel",
  SHIPMENT_VIEW: "shipment:view",
} as const;

// =====================================
// ROLE → PERMISSIONS MAP
// =====================================

export const rolePermissions: Record<Role, Permission[]> = {
  superadmin: [
    PERMISSIONS.USER_VIEW,

    PERMISSIONS.INVENTORY_VIEW,
    PERMISSIONS.INVENTORY_ADJUST,

    PERMISSIONS.PRODUCT_CREATE,
    PERMISSIONS.PRODUCT_UPDATE,

    PERMISSIONS.SHIPMENT_CREATE,
    PERMISSIONS.SHIPMENT_UPDATE,
    PERMISSIONS.SHIPMENT_CANCEL,
    PERMISSIONS.SHIPMENT_VIEW,
  ],

  admin: [
    PERMISSIONS.USER_VIEW,

    PERMISSIONS.INVENTORY_VIEW,
    PERMISSIONS.INVENTORY_ADJUST,

    PERMISSIONS.PRODUCT_CREATE,
    PERMISSIONS.PRODUCT_UPDATE,

    PERMISSIONS.SHIPMENT_CREATE,
    PERMISSIONS.SHIPMENT_UPDATE,
    PERMISSIONS.SHIPMENT_CANCEL,
    PERMISSIONS.SHIPMENT_VIEW,
  ],

  manager: [
    PERMISSIONS.USER_VIEW,

    PERMISSIONS.INVENTORY_VIEW,
    PERMISSIONS.INVENTORY_ADJUST,

    PERMISSIONS.SHIPMENT_CREATE,
    PERMISSIONS.SHIPMENT_UPDATE,
    PERMISSIONS.SHIPMENT_VIEW,
  ],

  operator: [
    PERMISSIONS.USER_VIEW,

    PERMISSIONS.INVENTORY_VIEW,

    PERMISSIONS.SHIPMENT_VIEW,
  ],
};

// =====================================
// HELPERS
// =====================================

export function hasPermission(role: Role, permission: Permission): boolean {
  return rolePermissions[role]?.includes(permission) ?? false;
}

export function hasMinRole(userRole: Role, minRole: Role): boolean {
  return roleHierarchy[userRole] >= roleHierarchy[minRole];
}

export function canManageRole(currentRole: Role, targetRole: Role): boolean {
  return roleHierarchy[currentRole] > roleHierarchy[targetRole];
}

export function getManageableRoles(currentRole: Role): Role[] {
  return (Object.values(ROLES) as Role[]).filter((role) =>
    canManageRole(currentRole, role),
  );
}

export function getVisibleRoles(currentRole: Role): Role[] {
  return (Object.values(ROLES) as Role[]).filter(
    (role) => role === currentRole || canManageRole(currentRole, role),
  );
}