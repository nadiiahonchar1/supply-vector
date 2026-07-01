import { ROLES, PERMISSIONS } from "@/lib/auth/permissions";

export type Role = (typeof ROLES)[keyof typeof ROLES];

export type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};

export type CreateUserInput = {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  role: Role;
  storeIds?: string[];
};

export type DeleteUserInput = {
  userId: string;
};

export type LoginInput = {
  email: string;
  password: string;
};

export type LoginResponse = {
  userId: string;
  email: string;
  sessionToken: string;
};

export type AuthUser = {
  id: string;
  role: Role;
};

export type Permission = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

export type CurrentUser = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
  role: Role;
};
