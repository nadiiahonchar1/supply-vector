"use server";

import { sql } from "@/db";
import { verifyPassword } from "@/lib/auth/password";
import { cookies } from "next/headers";

export async function loginAction(email: string, password: string) {
  const users = await sql`
    SELECT *
    FROM users
    WHERE email = ${email}
      AND is_active = true
  `;

  const user = users[0];

  if (!user) {
    throw new Error("Invalid credentials");
  }

  const isValid = await verifyPassword(password, user.password_hash);

  if (!isValid) {
    throw new Error("Invalid credentials");
    }
    
    const cookieStore = await cookies();
  
  cookieStore.set("session", user.id, {
    httpOnly: true,
    path: "/",
    secure: process.env.NODE_ENV === "production",
  });

  return {
    id: user.id,
    email: user.email,
  };
}
