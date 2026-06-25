"use server";

import { cookies } from "next/headers";
import { requireUser, logoutUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";

export async function logoutAction() {
  const currentUser = await requireUser();

  const token = (await cookies()).get("session")?.value;

  if (token) {
    await logoutUser(token);
  }

  await AuditService.log({
    userId: currentUser.id,
    action: "auth:logout",
    entity: "auth",
    entityId: currentUser.id,
  });

  return {
    success: true,
  };
}
