import { NextResponse } from "next/server";
import { loginUser } from "@/lib/auth/auth-service";
import { AuditService } from "@/lib/audit/audit.service";

export async function POST(req: Request) {
  const body = await req.json();

  const result = await loginUser(body.email, body.password);

  await AuditService.log({
    userId: result.userId,
    action: "auth:login",
    entity: "auth",
    entityId: result.userId,
  });

  return NextResponse.json({
    success: true,
  });
}
