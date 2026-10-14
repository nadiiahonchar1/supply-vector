"use client";

import { useAuth } from "@/features/auth";

export const useLogout = () => {
  const { logout } = useAuth();

  return { logout };
};
