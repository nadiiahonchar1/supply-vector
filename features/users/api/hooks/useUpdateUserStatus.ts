import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "../users.api";
import type { UpdateUserStatusRequest } from "../../types";

export function useUpdateUserStatus() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ userId, is_active }: UpdateUserStatusRequest) =>
      usersApi.updateStatus(userId, {
        is_active,
      }),

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}