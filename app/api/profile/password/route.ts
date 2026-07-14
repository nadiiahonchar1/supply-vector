import { NextResponse } from "next/server";

import { ProfileService } from "@/lib/profile/profile.service";

export async function POST(req: Request) {
  try {
    const body = await req.json();

    await ProfileService.changePassword(body);

    return NextResponse.json({
      success: true,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Internal server error";

    let status = 500;

    if (message === "Unauthorized") {
      status = 401;
    }

    if (
      message === "Current password is incorrect" ||
      message === "User not found"
    ) {
      status = 400;
    }

    return NextResponse.json({ message }, { status });
  }
}
