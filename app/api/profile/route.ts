import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";

export async function GET() {
  try {
    const profile = await ProfileService.getProfile();

    return NextResponse.json(profile);
  } catch {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 });
  }
}

export async function PATCH(req: Request) {
  try {
    const body = await req.json();

    const profile = await ProfileService.updateProfile(body);

    return NextResponse.json(profile);
  } catch (error) {
    return NextResponse.json(
      {
        message:
          error instanceof Error ? error.message : "Internal server error",
      },
      {
        status:
          error instanceof Error && error.message === "Unauthorized"
            ? 401
            : 500,
      },
    );
  }
}
