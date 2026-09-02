export type AuditAction =
  // AUTH
  | "auth:login"
  | "auth:logout"
  | "password:change"

  // USERS
  | "user:create"
  | "user:update"
  | "user:change-role"
  | "user:activate"
  | "user:deactivate"

//STORES
  | "store:create"
  | "store:update";

export type AuditMeta =
  | {
      reason?: string;
      changes?: Record<string, { from: unknown; to: unknown }>;
      entity?: string;
      entityId?: string;
    }
  | Record<string, unknown>;
