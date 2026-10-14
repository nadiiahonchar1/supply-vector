import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "@/features/users";

import type { User, ChangeRoleRequest } from "@/features/users";

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