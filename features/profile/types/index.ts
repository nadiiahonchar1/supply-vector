import type { Role } from "@/features/auth";
export type Profile = {
  id: string;

  email: string;

  first_name: string;

  last_name: string;

  role: Role;

  is_active: boolean;
};

export type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};
