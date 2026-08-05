import { NextResponse, NextRequest } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { UsersService } from "@/lib/users";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";

export async function GET(request: NextRequest) {
 const page = Number(request.nextUrl.searchParams.get("page") ?? 1);

 const limit = Number(request.nextUrl.searchParams.get("limit") ?? 20);
  try {
    const users = await UsersService.getUsers({
      page,
      limit,
    });

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
