import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { sql } from "@/db";

export async function middleware(req: NextRequest) {
  const token = req.cookies.get("session")?.value;

  const isLoginPage = req.nextUrl.pathname === "/login";

  if (isLoginPage) {
    return NextResponse.next();
  }

  if (!token) {
    return NextResponse.redirect(new URL("/login", req.url));
  }

  const sessions = await sql`
    SELECT
      s.user_id,
      s.expires_at,
      u.is_active
    FROM sessions s
    JOIN users u ON u.id = s.user_id
    WHERE s.token = ${token}
    LIMIT 1
  `;

  const session = sessions[0];

  if (!session) {
    const res = NextResponse.redirect(new URL("/login", req.url));
    res.cookies.delete("session");
    return res;
  }

  if (!session.is_active) {
    const res = NextResponse.redirect(new URL("/login", req.url));
    res.cookies.delete("session");
    return res;
  }

  if (new Date(session.expires_at) < new Date()) {
    const res = NextResponse.redirect(new URL("/login", req.url));
    res.cookies.delete("session");
    return res;
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next|api|favicon.ico).*)"],
};
