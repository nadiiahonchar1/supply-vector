import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { UsersService } from "@/lib/users/users.service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function GET() {
  try {
    const users = await UsersService.getUsers();

    return NextResponse.json(users);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(req: Request) {
  try {
    const input = await req.json();

    const currentUser = await requireUser();

    const result = await UsersService.createUser(input);

    await AuditService.log({
      userId: currentUser.id,
      action: "user:create",
      entity: "users",
      entityId: result.user.id,
      meta: {
        createdUserEmail: result.user.email,
        role: result.user.role,
      },
    });

    return NextResponse.json(result, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}
