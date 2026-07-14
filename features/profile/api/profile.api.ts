import { apiClient } from "@/lib/api-client";

import type {
  Profile,
  UpdateProfileInput,
  ChangePasswordInput,
} from "../types";

export const ProfileApi = {
  getProfile() {
    return apiClient.get<Profile>("/api/profile");
  },

  updateProfile(data: UpdateProfileInput) {
    return apiClient.patch<Profile>("/api/profile", data);
  },

  changePassword(data: ChangePasswordInput) {
    return apiClient.post<{ success: true }>("/api/profile/password", data);
  },
};
