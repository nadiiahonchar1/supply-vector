import { useQuery } from "@tanstack/react-query";

import { usersApi } from "../users.api";

export function useUsers(page: number) {
  return useQuery({
    queryKey: ["users", page],

    queryFn: () => usersApi.getUsers(page, 20),
  });
}
