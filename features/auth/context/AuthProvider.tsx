"use client";

import { useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";

import { AuthContext } from "./AuthContext";

import { logout } from "../api/auth.api";
import type { CurrentUser } from "../types";

type AuthProviderProps = {
  children: React.ReactNode;
  initialUser: CurrentUser | null;
};

export function AuthProvider({ children, initialUser }: AuthProviderProps) {
  const router = useRouter();

  const handleLogout = useCallback(async () => {
    await logout();

    router.replace("/login");
    router.refresh();
  }, [router]);

  const value = useMemo(
    () => ({
      user: initialUser,
      setUser: () => {},
      logout: handleLogout,
      isAuthenticated: initialUser !== null,
    }),
    [initialUser, handleLogout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
