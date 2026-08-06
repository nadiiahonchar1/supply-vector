import { PERMISSIONS, ROLES } from "@/lib/auth/permissions";

export type Role = (typeof ROLES)[keyof typeof ROLES];

export type Permission = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

// =====================================
// AUTH
// =====================================

export type LoginInput = {
  email: string;
  password: string;
};

export type LoginResponse = {
  userId: string;
  email: string;
  sessionToken: string;
  mustChangePassword: boolean;
};

// =====================================
// CURRENT USER
// =====================================

export type AuthUser = {
  id: string;
  role: Role;
};

export type CurrentUser = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
  role: Role;
};
