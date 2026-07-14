import { apiClient } from "@/lib/api-client";
import type {
  CurrentUser,
  LoginInput,
  LoginResponse,
} from "../types";

function login(data: LoginInput) {
  return apiClient.post<LoginResponse>("/api/auth/login", data);
}

function me() {
  return apiClient.get<CurrentUser>("/api/auth/me");
}

function logout() {
  return apiClient.post<{ success: boolean }>("/api/auth/logout");
}

// function changePassword(data: ChangePasswordInput) {
//   return apiClient.post<{ success: boolean }>(
//     "/api/auth/change-password",
//     data,
//   );
// }

export { login, logout, me };