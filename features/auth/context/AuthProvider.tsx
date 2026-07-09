"use client";

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
} from "react";
import { useRouter } from "next/navigation";

import { logout } from "../api/auth.api";
import type { CurrentUser } from "../types";

type AuthContextValue = {
  user: CurrentUser | null;
  setUser: (user: CurrentUser | null) => void;
  logout: () => Promise<void>;
  isAuthenticated: boolean;
};

const AuthContext = createContext<AuthContextValue | null>(null);

type AuthProviderProps = {
  children: React.ReactNode;
  initialUser: CurrentUser | null;
};

export function AuthProvider({ children, initialUser }: AuthProviderProps) {
  const router = useRouter();

  const [user, setUser] = useState(initialUser);

  const handleLogout = useCallback(async () => {
    await logout();

    setUser(null);

    router.replace("/login");
    router.refresh();
  }, [router]);

  const value = useMemo<AuthContextValue>(
    () => ({
      user,
      setUser,
      logout: handleLogout,
      isAuthenticated: user !== null,
    }),
    [user, handleLogout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);

  if (!context) {
    throw new Error("useAuth must be used inside AuthProvider");
  }

  return context;
}
