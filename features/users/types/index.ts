import type { Role } from "@/features/auth";

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
