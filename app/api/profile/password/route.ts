import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";
import { validate } from "@/lib/validation/validate";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { changePasswordSchema } from "@/features/profile/validation/password.schema";

export async function POST(req: Request) {
  try {
    const body = validate(changePasswordSchema, await req.json());

    await ProfileService.changePassword(body);

    return NextResponse.json({
      success: true,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
