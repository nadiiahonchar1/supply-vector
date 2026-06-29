import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { logoutUser } from "@/lib/auth/auth-service";

export async function POST() {
  const token = (await cookies()).get("session")?.value;

  if (token) {
    await logoutUser(token);
  }

  return NextResponse.json({ success: true });
}
