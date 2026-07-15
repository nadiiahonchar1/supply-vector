import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";
import { validate } from "@/lib/validation/validate";
import { handleApiError } from "@/lib/errors/handle-api-error";

import { updateProfileSchema } from "@/features/profile/validation/profile.schema";

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
