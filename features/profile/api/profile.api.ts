import { apiClient } from "@/lib/api-client";

import type {
  Profile,
  UpdateProfileInput,
  ChangePasswordInput,
} from "../types";

export function getProfile() {
  return apiClient.get<Profile>("/api/profile");
}

export function updateProfile(data: UpdateProfileInput) {
  return apiClient.patch<Profile>("/api/profile", data);
}

export function changePassword(data: ChangePasswordInput) {
  return apiClient.post<{ success: boolean }>("/api/profile/password", data);
}
