import { useMutation, useQueryClient } from "@tanstack/react-query";

import { usersApi } from "../users.api";

import type { CreateUserInput, CreateUserResponse } from "../../types";

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
