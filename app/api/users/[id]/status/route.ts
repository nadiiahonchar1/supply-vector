import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { UsersService } from "@/lib/users";
import { AuditService } from "@/lib/audit";
import { handleApiError } from "@/lib/errors";
import { validate } from "@/lib/validation";
import { updateUserStatusSchema } from "@/features/users/validation/user.schema";

type Params = {
  params: Promise<{
    id: string;
  }>;
};

export async function PATCH(req: Request, { params }: Params) {
  try {
    const { id } = await params;

    const body = validate(updateUserStatusSchema, await req.json());

    const currentUser = await requireUser();

    const user = await UsersService.updateUserStatus(id, body);

    await AuditService.log({
      userId: currentUser.id,
      action: user.is_active ? "user:activate" : "user:deactivate",
      entity: "users",
      entityId: user.id,
    });

    return NextResponse.json(user);
  } catch (error) {
    return handleApiError(error);
  }
}
