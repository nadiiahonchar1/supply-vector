"use client";

import { Controller, useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";

import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

import { ROLES, canManageRole } from "@/lib/auth/permissions";
import { useAuth } from "@/features/auth";

import { USERS_TEXT } from "../../constants/users-text";
import { changeRoleSchema } from "../../validation/user.schema";
import { useChangeRole } from "../../api";
import type { User, ChangeRoleInput } from "../../types";

type Props = {
  user: User;
  onSuccess: () => void;
};

export function ChangeRoleForm({ user, onSuccess }: Props) {
  const {
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<ChangeRoleInput>({
    resolver: zodResolver(changeRoleSchema),
    defaultValues: {
      role: user.role,
    },
  });

  const { mutateAsync, isPending, error } = useChangeRole();
  const { user: currentUser } = useAuth();
  if (!currentUser) {
    return null;
  }

  const roleOptions = Object.values(ROLES)
    .filter((role) => canManageRole(currentUser.role, role))
    .map((role) => ({
      value: role,
      label: USERS_TEXT.role[role],
    }));

  const onSubmit = async (data: ChangeRoleInput) => {
    try {
      await mutateAsync({
        userId: user.id,
        role: data.role,
      });

      toast.success("Роль користувача успішно змінена");

      onSuccess();
    } catch {}
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-5">
      <div className="space-y-2">
        <label>{USERS_TEXT.table.role}</label>

        <Controller
          control={control}
          name="role"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>

              <SelectContent>
                {roleOptions.map((role) => (
                  <SelectItem key={role.value} value={role.value}>
                    {role.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />

        {errors.role && (
          <p className="text-sm text-destructive">{errors.role.message}</p>
        )}
      </div>

      {error && <p className="text-sm text-destructive">{error.message}</p>}

      <Button type="submit" className="w-full" disabled={isPending}>
        {isPending ? USERS_TEXT.loading : USERS_TEXT.actions.changeRole}
      </Button>
    </form>
  );
}
