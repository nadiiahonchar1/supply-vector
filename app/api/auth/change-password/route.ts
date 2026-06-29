import { NextResponse } from "next/server";
import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";

export async function POST(req: Request) {
  const input = await req.json();

  const currentUser = await requireUser();

  await UserManagementService.changePassword(currentUser, input);

  await AuditService.log({
    userId: currentUser.id,
    action: "password:change",
    entity: "users",
    entityId: currentUser.id,
  });

  return NextResponse.json({ success: true });
}
