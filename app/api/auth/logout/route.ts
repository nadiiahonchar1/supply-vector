import { NextResponse } from "next/server";
import { cookies } from "next/headers";

import { logoutUser, requireUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function POST() {
  try {
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

    return NextResponse.json({
      success: true,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
