import { apiClient } from "@/lib/api-client";

import type {
  User,
  CreateUserInput,
  CreateUserResponse,
  ChangeRoleInput,
  UpdateUserStatusInput,
} from "../types";

export const usersApi = {
  getUsers() {
    return apiClient.get<User[]>("/api/users");
  },

  createUser(data: CreateUserInput) {
    return apiClient.post<CreateUserResponse>("/api/users", data);
  },

  changeRole(userId: string, data: ChangeRoleInput) {
    return apiClient.patch<User>(`/api/users/${userId}/role`, data);
  },

  updateStatus(userId: string, data: UpdateUserStatusInput) {
    return apiClient.patch<User>(`/api/users/${userId}/status`, data);
  },
};
