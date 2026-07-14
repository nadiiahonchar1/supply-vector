import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function POST(req: Request) {
  try {
    const body = await req.json();

    await ProfileService.changePassword(body);

    return NextResponse.json({
      success: true,
    });
  } catch (error) {
    return handleApiError(error);
  }
}
