"use client";

import { useAuth } from "../context/AuthProvider";

export const useLogout = () => {
  const { logout } = useAuth();

  return { logout };
};
