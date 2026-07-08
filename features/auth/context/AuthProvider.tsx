"use client";

import { useCallback, useMemo, useState } from "react";

import { logout as logoutApi, me } from "../api/auth.api";
import type { CurrentUser } from "../types";

import { AuthContext } from "./AuthContext";

type AuthProviderProps = {
  children: React.ReactNode;
  initialUser: CurrentUser | null;
};

export function AuthProvider({ children, initialUser }: AuthProviderProps) {
  const [user, setUser] = useState<CurrentUser | null>(initialUser);

  const refreshUser = useCallback(async () => {
    try {
      const currentUser = await me();

      setUser(currentUser);
    } catch {
      setUser(null);
    }
  }, []);

  const logout = useCallback(async () => {
    try {
      await logoutApi();
    } finally {
      setUser(null);
    }
  }, []);

  const value = useMemo(
    () => ({
      user,
      loading: false,
      refreshUser,
      logout,
    }),
    [user, refreshUser, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
