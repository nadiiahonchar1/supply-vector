"use client";

import { createContext } from "react";

import type { CurrentUser } from "../types";

export type AuthContextValue = {
  user: CurrentUser | null;
  setUser: (user: CurrentUser | null) => void;
  logout: () => Promise<void>;
  isAuthenticated: boolean;
};

export const AuthContext = createContext<AuthContextValue | null>(null);
