"use client";

import { ProfileApi } from "@/features/profile";
import type { ChangePasswordInput } from "@/features/profile";

export function useChangePassword() {
  async function changePassword(data: ChangePasswordInput) {
    return ProfileApi.changePassword(data);
  }

  return {
    changePassword,
  };
}
