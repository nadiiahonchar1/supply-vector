"use client";

import { useAuth } from "../../context/useAuth";

export const useLogout = () => {
  const { logout } = useAuth();

  return { logout };
};
