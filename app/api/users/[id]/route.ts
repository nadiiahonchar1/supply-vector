import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/auth-service";
import { UserManagementService } from "@/lib/users/user-management.service";
import { AuditService } from "@/lib/audit/audit.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

type Params = {
  params: {
    id: string;
  };
};

// =====================================
// GET USER BY ID
// =====================================
export async function GET(_: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();  
    const user = await UserManagementService.getUserById(currentUser, params.id);  
    return NextResponse.json(user);
  }catch(error){return handleApiError(error)}
}

// =====================================
// DELETE USER
// =====================================
export async function DELETE(_: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();  
    const result = await UserManagementService.deleteUser(currentUser, params.id);  
    await AuditService.log({
      userId: currentUser.id,
      action: "user:delete",
      entity: "users",
      entityId: params.id,
    });  
    return NextResponse.json(result);    
  }catch(error){return handleApiError(error)}
}
