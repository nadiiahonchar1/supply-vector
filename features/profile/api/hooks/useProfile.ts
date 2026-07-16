"use client";

import { useCallback, useState } from "react";

import { ProfileApi } from "../profile.api";

import type { Profile } from "../../types";

export function useProfile() {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadProfile = useCallback(async () => {
    try {
      setIsLoading(true);

      const data = await ProfileApi.getProfile();

      setProfile(data);
      setError(null);

      return data;
    } catch (e) {
      const message = e instanceof Error ? e.message : "Failed to load profile";

      setError(message);

      throw e;
    } finally {
      setIsLoading(false);
    }
  }, []);

  return {
    profile,
    setProfile,
    isLoading,
    error,
    loadProfile,
  };
}
