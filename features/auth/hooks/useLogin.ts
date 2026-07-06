"use client";

import { useRouter } from "next/navigation";

import { login as loginApi } from "../api/auth.api";
import type { LoginInput } from "../types";

export function useLogin() {
  const router = useRouter();

  const login = async (data: LoginInput) => {
    const result = await loginApi(data);

    router.replace("/");
    router.refresh();

    return result;
  };

  return { login };
}
