"use client";

import { ProfileApi } from "../profile.api";

export function useProfile() {
  async function getProfile() {
    return ProfileApi.getProfile();
  }

  return {
    getProfile,
  };
}
