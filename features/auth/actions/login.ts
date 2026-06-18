"use server";

import { loginUser } from "@/lib/auth/auth-service";

type LoginInput = {
  email: string;
  password: string;
};

export async function loginAction({ email, password }: LoginInput) {
  await loginUser(email, password);

  return {
    success: true,
  };
}
