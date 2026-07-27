import { NextResponse } from "next/server";

import { UsersService } from "@/lib/users/users.service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

type Params = {
  params: Promise<{
    id: string;
  }>;
};

export async function PATCH(req: Request, { params }: Params) {
  try {
    const { id } = await params;

    const body = await req.json();

    const user = await UsersService.updateUserStatus(id, body);

    await AuditService.log({
      userId: user.id,
      action: user.is_active ? "user:activate" : "user:deactivate",
      entity: "users",
      entityId: user.id,
    });

    return NextResponse.json(user);
  } catch (error) {
    return handleApiError(error);
  }
}
