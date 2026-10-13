import { NextResponse } from "next/server";
import { changePasswordSchema } from "@/features/profile";
import { ProfileService } from "@/lib/profile";
import { validate } from "@/lib/validation";
import { handleApiError } from "@/lib/errors";

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
