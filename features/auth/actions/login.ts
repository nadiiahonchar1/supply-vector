"use server";

import { loginUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";

type LoginInput = {
  email: string;
  password: string;
};

export async function loginAction({ email, password }: LoginInput) {
  await loginUser(email, password);
  await AuditService.log({
    userId: user.id,
    action: "auth:login",
    entity: "auth",
    entityId: user.id,
  });

  return {
    success: true,
  };
}
