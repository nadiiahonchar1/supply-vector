import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "../users.api";
import type { Role } from "@/features/auth";

export function useChangeRole() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ userId, role }: { userId: string; role: Role }) =>
      usersApi.changeRole(userId, {
        role,
      }),

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}
