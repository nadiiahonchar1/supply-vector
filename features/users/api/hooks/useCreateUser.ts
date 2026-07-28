import { useMutation, useQueryClient } from "@tanstack/react-query";
import type { CreateUserInput } from "../../types";
import { usersApi } from "../users.api";

export function useCreateUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateUserInput) => usersApi.createUser(data),

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["users"],
      });
    },
  });
}
