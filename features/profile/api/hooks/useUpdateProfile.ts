"use client";

import { ProfileApi } from "../profile.api";
import type { UpdateProfileInput } from "../../types";

export function useUpdateProfile() {
  async function updateProfile(data: UpdateProfileInput) {
    return ProfileApi.updateProfile(data);
  }

  return {
    updateProfile,
  };
}
