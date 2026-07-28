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

// =====================================
// CREATE
// =====================================

export type CreateUserInput = {
  email: string;

  first_name: string;
  last_name: string;

  role: Role;

  storeIds?: string[];
};

export type CreateUserResponse = {
  user: User;
  temporaryPassword: string;
};

// =====================================
// UPDATE
// =====================================

export type ChangeRoleInput = {
  role: Role;
};

export type UpdateUserStatusInput = {
  is_active: boolean;
};

// =====================================
// MUTATIONS
// =====================================

export type ChangeRoleRequest = {
  userId: string;
  role: Role;
};

export type UpdateUserStatusRequest = {
  userId: string;
  is_active: boolean;
};
