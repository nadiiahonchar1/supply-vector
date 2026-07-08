import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth/session";

const PUBLIC_PATHS = ["/login", "/api/auth", "/_next", "/favicon.ico"];

export async function proxy(req: NextRequest) {
  const token = req.cookies.get("session")?.value;
  const { pathname } = req.nextUrl;

  const isPublic = PUBLIC_PATHS.some((path) => pathname.startsWith(path));

  if (isPublic) {
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
