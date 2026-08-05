"use client";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui";
import type { User } from "../../types";
import { USERS_TEXT } from "../../constants/users-text";
import { ChangeUserStatusForm } from "../forms";

type Props = {
  user: User;
  open: boolean;
  onOpenChange: (open: boolean) => void;
};

export function ChangeUserStatusDialog({ user, open, onOpenChange }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {user.is_active
              ? USERS_TEXT.actions.deactivate
              : USERS_TEXT.actions.activate}
          </DialogTitle>
        </DialogHeader>

        <ChangeUserStatusForm
          user={user}
          onSuccess={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}
