import { NextResponse } from "next/server";

import { loginUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";

export async function POST(req: Request) {
  const input = await req.json();

  const result = await loginUser(input.email, input.password);

  await AuditService.log({
    userId: result.userId,
    action: "auth:login",
    entity: "auth",
    entityId: result.userId,
  });

  return NextResponse.json(result);
}
