"use client";

import { useRouter } from "next/navigation";

import { login } from "../api/auth.api";
import type { LoginInput } from "../types";

export function useLogin() {
  const router = useRouter();

  async function signIn(data: LoginInput) {
    const result = await login(data);

    router.replace("/");
    router.refresh();

    return result;
  }

  return {
    login: signIn,
  };
}
