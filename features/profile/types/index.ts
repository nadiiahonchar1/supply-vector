export type Profile = {
  id: string;

  email: string;

  first_name: string;

  last_name: string;

  role: string;

  is_active: boolean;
};

export type UpdateProfileInput = {
  first_name: string;
  last_name: string;
};

export type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};
