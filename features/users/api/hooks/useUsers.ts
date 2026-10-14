import { useQuery } from "@tanstack/react-query";
import { usersApi } from "@/features/users";

export function useUsers(page: number) {
  return useQuery({
    queryKey: ["users", page],

    queryFn: () => usersApi.getUsers(page, 20),
  });
}
