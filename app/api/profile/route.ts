import { NextResponse } from "next/server";

import { updateProfileSchema } from "@/features/profile";
import { ProfileService } from "@/lib/profile";
import { validate } from "@/lib/validation";
import { handleApiError } from "@/lib/errors";

export async function GET() {
  try {
    const profile = await ProfileService.getProfile();

    return NextResponse.json(profile);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(req: Request) {
  try {
    const body = validate(updateProfileSchema, await req.json());

    const profile = await ProfileService.updateProfile(body);

    return NextResponse.json(profile);
  } catch (error) {
    return handleApiError(error);
  }
}
