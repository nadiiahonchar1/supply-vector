import type { Metadata } from "next";
import { Inter } from "next/font/google";

import "./globals.css";

import { getCurrentUser } from "@/lib/auth/get-current-user";

import { AppShell } from "@/features/app-shell/AppShell";

import { AppProviders } from "@/providers/AppProviders";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
});

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "SupplyVector",
  description: "SupplyVector",
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const currentUser = await getCurrentUser();

  return (
    <html lang="uk">
      <body className={`${inter.variable} antialiased`}>
        <AppProviders initialUser={currentUser}>
          <AppShell>{children}</AppShell>
        </AppProviders>
      </body>
    </html>
  );
}
