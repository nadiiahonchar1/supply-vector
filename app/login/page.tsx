"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { loginAction } from "@/features/auth/actions/login";

export default function LoginPage() {
  const router = useRouter();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();

    try {
      await loginAction(email, password);
      router.push("/shipments");
      router.refresh();
    } catch (e: unknown) {
      console.error("AUTH_ERROR", e);

      return Response.json({ error: "Invalid credentials" }, { status: 401 });
    }
  }

  return (
    <form onSubmit={handleLogin} style={{ display: "grid", gap: 10 }}>
      <input
        placeholder="Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />

      <input
        type="password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />

      <button type="submit">Login</button>
    </form>
  );
}
