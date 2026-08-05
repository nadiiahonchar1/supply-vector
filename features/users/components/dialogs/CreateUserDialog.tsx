"use client";

import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui";
import { CreateUserForm } from "./CreateUserForm";
import { CreateUserSuccessDialog } from "./CreateUserSuccessDialog";
import { USERS_TEXT } from "../../constants/users-text";

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
};

export function CreateUserDialog({ open, onOpenChange }: Props) {
  const [temporaryPassword, setTemporaryPassword] = useState<string | null>(
    null,
  );

  const successOpen = temporaryPassword !== null;

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{USERS_TEXT.creating}</DialogTitle>
          </DialogHeader>

          <CreateUserForm
            onSuccess={(password) => {
              onOpenChange(false);
              setTemporaryPassword(password);
            }}
          />
        </DialogContent>
      </Dialog>

      <CreateUserSuccessDialog
        open={successOpen}
        password={temporaryPassword}
        onClose={() => {
          setTemporaryPassword(null);
        }}
      />
    </>
  );
}
