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
    return apiClient.get<User[]>("/users");
  },

  createUser(data: CreateUserInput) {
    return apiClient.post<CreateUserResponse>("/users", data);
  },

  changeRole(userId: string, data: ChangeRoleInput) {
    return apiClient.patch<User>(`/users/${userId}/role`, data);
  },

  updateStatus(userId: string, data: UpdateUserStatusInput) {
    return apiClient.patch<User>(`/users/${userId}/status`, data);
  },
};
