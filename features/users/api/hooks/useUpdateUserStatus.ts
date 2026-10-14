import { useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "@/features/users";

import type { User, UpdateUserStatusRequest } from "@/features/users";

export function useUpdateUserStatus() {
  const queryClient = useQueryClient();

   return useMutation<User, Error, UpdateUserStatusRequest>({
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