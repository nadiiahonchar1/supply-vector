"use client";

import type { PropsWithChildren } from "react";
import { QueryClientProvider } from "@tanstack/react-query";

import { queryClient } from "@/lib/react-query";
import { AuthProvider } from "@/features/auth/context/AuthProvider";

import type { CurrentUser } from "@/features/auth/types";

type AppProvidersProps = PropsWithChildren<{
  initialUser: CurrentUser | null;
}>;

export function AppProviders({ children, initialUser }: AppProvidersProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider initialUser={initialUser}>{children}</AuthProvider>
    </QueryClientProvider>
  );
}
