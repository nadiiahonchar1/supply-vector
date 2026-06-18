"use server";

import { cookies } from "next/headers";

import { logoutUser } from "@/lib/auth/auth-service";

export async function logoutAction() {
  const token = (await cookies()).get("session")?.value;

  if (token) {
    await logoutUser(token);
  }

  return {
    success: true,
  };
}
