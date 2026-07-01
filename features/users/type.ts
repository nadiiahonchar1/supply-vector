import type { Role } from "@/features/auth/types";

// =====================================
// USERS
// =====================================

export type User = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
  role: Role;
};

export type UpdateUserInput = {
  firstName: string;
  lastName: string;
  role: Role;
  isActive: boolean;
  storeIds?: string[];
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
