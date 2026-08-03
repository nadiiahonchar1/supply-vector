import { apiClient } from "@/lib/api-client";

import type {
  User,
  CreateUserInput,
  CreateUserResponse,
  ChangeRoleInput,
  UpdateUserStatusInput,
  PaginatedUsersResponse,
} from "../types";

export const usersApi = {
  getUsers(page = 1, limit = 20): Promise<PaginatedUsersResponse> {
    return apiClient.get<PaginatedUsersResponse>(
      `/api/users?page=${page}&limit=${limit}`,
    );
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
