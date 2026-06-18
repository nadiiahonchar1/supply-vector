export const ROLES = {
  SUPER_ADMIN: "superadmin",
  ADMIN: "admin",
  MANAGER: "manager",
  VIEWER: "viewer",
} as const;

export type Role = (typeof ROLES)[keyof typeof ROLES];

// =====================================
// ROLE HIERARCHY (для швидких перевірок)
// =====================================
export const roleHierarchy: Record<Role, number> = {
  superadmin: 4,
  admin: 3,
  manager: 2,
  viewer: 1,
};

// =====================================
// PERMISSIONS (ключова частина)
// =====================================
export const PERMISSIONS = {
  // USERS
  USER_CREATE: "user:create",
  USER_DELETE: "user:delete",
  USER_UPDATE: "user:update",
  USER_VIEW: "user:view",

  // ROLES
  ROLE_ASSIGN: "role:assign",

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

export type Permission = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

// =====================================
// ROLE → PERMISSIONS MAP
// =====================================
export const rolePermissions: Record<Role, Permission[]> = {
  superadmin: [
    PERMISSIONS.USER_CREATE,
    PERMISSIONS.USER_DELETE,
    PERMISSIONS.USER_UPDATE,
    PERMISSIONS.USER_VIEW,
    PERMISSIONS.ROLE_ASSIGN,

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
    PERMISSIONS.USER_CREATE,
    PERMISSIONS.USER_UPDATE,
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
    PERMISSIONS.INVENTORY_VIEW,
    PERMISSIONS.INVENTORY_ADJUST,

    PERMISSIONS.SHIPMENT_CREATE,
    PERMISSIONS.SHIPMENT_UPDATE,
    PERMISSIONS.SHIPMENT_VIEW,
  ],

  viewer: [PERMISSIONS.SHIPMENT_VIEW, PERMISSIONS.INVENTORY_VIEW],
};

// =====================================
// HELPERS
// =====================================
export function hasPermission(role: Role, permission: Permission): boolean {
  return rolePermissions[role]?.includes(permission) ?? false;
}

export function canAccess(userRoles: Role[], permission: Permission): boolean {
  return userRoles.some((role) => hasPermission(role, permission));
}

export function hasMinRole(userRole: Role, minRole: Role): boolean {
  return roleHierarchy[userRole] >= roleHierarchy[minRole];
}

export function canManageRole(currentRole: Role, targetRole: Role): boolean {
  return roleHierarchy[currentRole] > roleHierarchy[targetRole];
}