"use client";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui";
import { USERS_TEXT } from "../../constants/users-text";
import { ChangeRoleForm } from "../forms/ChangeRoleForm";
import type { User } from "../../types";

type Props = {
  user: User;
  open: boolean;
  onOpenChange: (open: boolean) => void;
};

export function ChangeRoleDialog({ user, open, onOpenChange }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{USERS_TEXT.actions.changeRole}</DialogTitle>
        </DialogHeader>

        <ChangeRoleForm user={user} onSuccess={() => onOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}
