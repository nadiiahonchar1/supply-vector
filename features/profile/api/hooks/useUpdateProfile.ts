"use client";

import { ProfileApi } from "../profile.api";

import type { Profile, UpdateProfileInput } from "../../types";

export function useUpdateProfile() {
  async function updateProfile(data: UpdateProfileInput): Promise<Profile> {
    return ProfileApi.updateProfile(data);
  }

  return {
    updateProfile,
  };
}
