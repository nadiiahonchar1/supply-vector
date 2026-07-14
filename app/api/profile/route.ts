import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

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
    const body = await req.json();

    const profile = await ProfileService.updateProfile(body);

    return NextResponse.json(profile);
  } catch (error) {
    return handleApiError(error);
  }
}