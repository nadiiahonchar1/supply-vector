"use server";

import { loginUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import type { LoginInput } from "../types";

export async function loginAction({ email, password }: LoginInput) {
  const result = await loginUser(email, password);

  await AuditService.log({
    userId: result.userId,
    action: "auth:login",
    entity: "auth",
    entityId: result.userId,
  });

  return {
    success: true,
  };
}
