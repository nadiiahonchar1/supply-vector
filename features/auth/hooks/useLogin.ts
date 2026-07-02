"use client";

import { useRouter } from "next/navigation";

import { AuthApi } from "../api/auth.api";
import type { LoginInput } from "../types";

export function useLogin() {
  const router = useRouter();

  async function login(data: LoginInput) {
    const result = await AuthApi.login(data);

    router.replace("/");
    router.refresh();

    return result;
  }

  return {
    login,
  };
}
