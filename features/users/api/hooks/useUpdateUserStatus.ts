import { useMutation, useQueryClient } from "@tanstack/react-query";

import { usersApi } from "../users.api";

export function useUpdateUserStatus() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      userId,
      is_active,
    }: {
      userId: string;
      is_active: boolean;
    }) =>
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
