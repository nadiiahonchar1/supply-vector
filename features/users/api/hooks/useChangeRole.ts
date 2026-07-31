import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "../users.api";
import type { User, ChangeRoleRequest } from "../../types";

export function useChangeRole() {
  const queryClient = useQueryClient();

  return useMutation<User, Error, ChangeRoleRequest>({
    mutationFn: ({ userId, role }) => usersApi.changeRole(userId, { role }),

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}