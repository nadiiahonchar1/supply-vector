"use client";

import toast from "react-hot-toast";

import { Button } from "@/components/ui/button";

import { useUpdateUserStatus } from "../../api";
import { USERS_TEXT } from "../../constants/users-text";

import type { User } from "../../types";

type Props = {
  user: User;
  onSuccess: () => void;
};

export function ChangeUserStatusForm({ user, onSuccess }: Props) {
  const { mutateAsync, isPending, error } = useUpdateUserStatus();

  async function handleSubmit() {
    await mutateAsync({
      userId: user.id,
      is_active: !user.is_active,
    });

    toast.success(
      user.is_active
        ? "Користувача успішно деактивовано"
        : "Користувача успішно активовано",
    );

    onSuccess();
  }

  return (
    <div className="space-y-6">
      <p className="text-sm text-muted-foreground">
        {user.is_active
          ? "Ви дійсно бажаєте деактивувати цього користувача?"
          : "Ви дійсно бажаєте активувати цього користувача?"}
      </p>

      {error && <p className="text-sm text-destructive">{error.message}</p>}

      <div className="flex justify-end gap-3">
        <Button variant="outline" onClick={onSuccess} disabled={isPending}>
          Скасувати
        </Button>

        <Button onClick={handleSubmit} disabled={isPending}>
          {isPending
            ? USERS_TEXT.loading
            : user.is_active
              ? USERS_TEXT.actions.deactivate
              : USERS_TEXT.actions.activate}
        </Button>
      </div>
    </div>
  );
}
