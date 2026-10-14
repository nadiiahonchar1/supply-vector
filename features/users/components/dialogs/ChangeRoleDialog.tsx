"use client";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui";
import { ChangeRoleForm, USERS_TEXT } from "@/features/users";

import type { User } from "@/features/users";

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
          <DialogTitle>{USERS_TEXT.actions.change_role}</DialogTitle>
        </DialogHeader>

        <ChangeRoleForm user={user} onSuccess={() => onOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}
