import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "../users.api";
import type { ChangeRoleRequest } from "../../types";

export function useChangeRole() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ userId, role }: ChangeRoleRequest) =>
      usersApi.changeRole(userId, { role }),

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}