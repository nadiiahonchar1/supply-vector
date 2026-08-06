import { NextResponse } from "next/server";

import { loginUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";

export async function POST(req: Request) {
  try {
    const body = await req.json();

    const result = await loginUser(body.email, body.password);

    await AuditService.log({
      userId: result.userId,
      action: "auth:login",
      entity: "auth",
      entityId: result.userId,
    });

    return NextResponse.json(result);
  } catch (error) {
    return handleApiError(error);
  }
}
