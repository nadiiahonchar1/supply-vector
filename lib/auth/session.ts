import { sql } from "@/db";
import { cookies } from "next/headers";

const SESSION_COOKIE = "session";
const SESSION_LIFETIME_DAYS = 7;

// =====================================
// CREATE SESSION
// =====================================
export async function createSession(userId: string) {
  const token = crypto.randomUUID();

  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + SESSION_LIFETIME_DAYS);

  await sql`
    INSERT INTO sessions (user_id, token, expires_at)
    VALUES (${userId}, ${token}, ${expiresAt})
  `;

  const cookieStore = await cookies();

  cookieStore.set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    expires: expiresAt,
  });

  return token;
}

// =====================================
// GET SESSION (FIXED SQL)
// =====================================
export async function getSession(token?: string) {
  if (!token) return null;

  const sessions = await sql`
    SELECT
      s.id,
      s.user_id,
      s.expires_at,
      u.is_active
    FROM sessions s
    JOIN users u ON u.id = s.user_id
    WHERE s.token = ${token}
      AND s.expires_at > NOW()
    LIMIT 1
  `;

  const session = sessions[0];

  if (!session) return null;
  if (!session.is_active) return null;

  return session;
}

// =====================================
// DELETE SESSION
// =====================================
export async function deleteSession(token: string) {
  await sql`
    DELETE FROM sessions
    WHERE token = ${token}
  `;

  const cookieStore = await cookies();
  cookieStore.delete(SESSION_COOKIE);
}

// =====================================
// GET SESSION FROM COOKIE
// =====================================
export async function getSessionFromCookie() {
  const cookieStore = await cookies();
  const token = cookieStore.get(SESSION_COOKIE)?.value;

  if (!token) return null;

  return getSession(token);
}
