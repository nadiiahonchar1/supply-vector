"use client";

import { createContext } from "react";

import type { CurrentUser } from "../types";

export type AuthContextValue = {
  user: CurrentUser | null;
  loading: boolean;

  refreshUser: () => Promise<void>;
  logout: () => Promise<void>;
};

export const AuthContext = createContext<AuthContextValue | undefined>(
  undefined,
);
