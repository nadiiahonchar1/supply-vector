"use client";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  Button,
} from "@/components/ui";
import { USERS_TEXT } from "../../constants/users-text";

type Props = {
  open: boolean;
  password: string | null;
  onClose: () => void;
};

export function CreateUserSuccessDialog({ open, password, onClose }: Props) {
  if (!password) {
    return null;
  }

  const copyPassword = async () => {
    await navigator.clipboard.writeText(password);
  };

  return (
    <Dialog open={open} onOpenChange={onClose}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{USERS_TEXT.success_dialog.success}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <p>{USERS_TEXT.success_dialog.temporary_password}</p>

          <div className="rounded-md border p-3 font-mono text-lg">
            {password}
          </div>

          <p className="text-sm text-muted-foreground">
            {USERS_TEXT.success_dialog.message}
          </p>

          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={copyPassword}>
              {USERS_TEXT.success_dialog.copy}
            </Button>

            <Button type="button" onClick={onClose}>
              {USERS_TEXT.success_dialog.close}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
