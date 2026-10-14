"use client";

import type { PropsWithChildren } from "react";
import { QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "react-hot-toast";
import { AuthProvider, CurrentUser } from "@/features/auth";
import { queryClient } from "@/lib/react-query";

type AppProvidersProps = PropsWithChildren<{
  initialUser: CurrentUser | null;
}>;

export function AppProviders({ children, initialUser }: AppProvidersProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider initialUser={initialUser}>{children}</AuthProvider>
      <Toaster position="top-right" />
    </QueryClientProvider>
  );
}
