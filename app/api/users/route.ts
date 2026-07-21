import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function GET() {
  const currentUser = await requireUser();

  const users = await UserManagementService.listUsers(currentUser);

  return NextResponse.json(users);
}

export async function POST(req: Request) {
  const input = await req.json();
  const currentUser = await requireUser();

  const result = await UserManagementService.createUser(currentUser, input);

  await AuditService.log({
    userId: currentUser.id,
    action: "user:create",
    entity: "users",
    entityId: result.userId,
  });

  return NextResponse.json(result);
}
