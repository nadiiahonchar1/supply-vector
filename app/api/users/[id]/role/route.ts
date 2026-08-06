import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { UsersService } from "@/lib/users";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";

type Params = {
  params: Promise<{
    id: string;
  }>;
};

export async function PATCH(req: Request, { params }: Params) {
  try {
    const { id } = await params;

    const body = await req.json();

    const currentUser = await requireUser();

    const user = await UsersService.changeRole(id, body);

    await AuditService.log({
      userId: currentUser.id,
      action: "user:change-role",
      entity: "users",
      entityId: user.id,
      meta: {
        newRole: user.role,
      },
    });

    return NextResponse.json(user);
  } catch (error) {
    return handleApiError(error);
  }
}
