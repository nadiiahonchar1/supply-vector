import type {
  LoginInput,
  LoginResponse,
  CurrentUser,
  ChangePasswordInput,
} from "@/features/auth/types";

// =====================================
// LOGIN
// =====================================

async function login(data: LoginInput): Promise<LoginResponse> {
  const res = await fetch("/api/auth/login", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(data),
  });

  if (!res.ok) {
    throw new Error("Login failed");
  }

  return res.json();
}

// =====================================
// ME
// =====================================

async function me(): Promise<CurrentUser> {
  const res = await fetch("/api/auth/me", {
    method: "GET",
    credentials: "include",
  });

  if (!res.ok) {
    throw new Error("Unauthorized");
  }

  return res.json();
}

// =====================================
// LOGOUT
// =====================================

async function logout(): Promise<{ success: boolean }> {
  const res = await fetch("/api/auth/logout", {
    method: "POST",
    credentials: "include",
  });

  if (!res.ok) {
    throw new Error("Logout failed");
  }

  return res.json();
}

// =====================================
// CHANGE PASSWORD
// =====================================

async function changePassword(data: ChangePasswordInput) {
  const res = await fetch("/api/auth/change-password", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(data),
    credentials: "include",
  });

  if (!res.ok) {
    throw new Error("Password change failed");
  }

  return res.json();
}

// =====================================
// EXPORT
// =====================================

export const AuthApi = {
  login,
  me,
  logout,
  changePassword,
};
