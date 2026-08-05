import { Badge } from "@/components/ui";
import { USERS_TEXT } from "../constants/users-text";

type Props = {
  isActive: boolean;
};

export function UserStatusBadge({ isActive }: Props) {
  return (
    <Badge variant={isActive ? "default" : "secondary"}>
      {isActive ? USERS_TEXT.status.active : USERS_TEXT.status.inactive}
    </Badge>
  );
}
