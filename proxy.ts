import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth/session";

export async function proxy(req: NextRequest) {
  const token = req.cookies.get("session")?.value;
  const { pathname } = req.nextUrl;

  if (
    pathname.startsWith("/login") ||
    pathname.startsWith("/_next") ||
    pathname === "/favicon.ico" ||
    pathname.startsWith("/api/auth")
  ) {
    return NextResponse.next();
  }

  if (!token) {
    return NextResponse.redirect(new URL("/login", req.url));
  }

  const session = await getSession(token);

  if (!session) {
    const res = NextResponse.redirect(new URL("/login", req.url));
    res.cookies.delete("session");
    return res;
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/:path*"],
};
