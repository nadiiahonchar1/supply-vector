"use client";

import { ProfileApi } from "../profile.api";
import type { ChangePasswordInput } from "../../types";

export function useChangePassword() {
  async function changePassword(data: ChangePasswordInput) {
    return ProfileApi.changePassword(data);
  }

  return {
    changePassword,
  };
}
