"use client";

import { ProfileApi } from "@/features/profile";
import type { Profile, UpdateProfileInput } from "@/features/profile";

export function useUpdateProfile() {
  async function updateProfile(data: UpdateProfileInput): Promise<Profile> {
    return ProfileApi.updateProfile(data);
  }

  return {
    updateProfile,
  };
}
