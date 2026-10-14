import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "@/features/users";

import type { CreateUserInput, CreateUserResponse } from "@/features/users";

export function useCreateUser() {
  const queryClient = useQueryClient();

  return useMutation<CreateUserResponse, Error, CreateUserInput>({
    mutationFn: usersApi.createUser,

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}
