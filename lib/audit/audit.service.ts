import { sql } from "@/db";

type AuditAction =
  | "user:create"
  | "user:delete"
  | "user:update"
  | "auth:login"
  | "auth:logout"
  | "password:change";

export type AuditMeta =
  | {
      reason?: string;
      changes?: Record<string, { from: unknown; to: unknown }>;
      entity?: string;
      entityId?: string;
    }
  | Record<string, unknown>;

export class AuditService {
  static async log(params: {
    userId?: string;
    action: AuditAction;
    entity: string;
    entityId?: string;
    meta?: AuditMeta;
    ipAddress?: string;
    userAgent?: string;
  }) {
    await sql`
      INSERT INTO audit_logs (
        user_id,
        action,
        entity,
        entity_id,
        meta,
        ip_address,
        user_agent,
        created_at
      )
      VALUES (
        ${params.userId ?? null},
        ${params.action},
        ${params.entity},
        ${params.entityId ?? null},
        ${params.meta ?? {}},
        ${params.ipAddress ?? null},
        ${params.userAgent ?? null},
        NOW()
      )
    `;
  }
}
