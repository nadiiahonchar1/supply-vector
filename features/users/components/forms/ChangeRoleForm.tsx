"use client";

import { Controller, useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";
import {
  Button,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui";
import { ROLES, canManageRole } from "@/lib/auth";
import { useAuth } from "@/features/auth";
import { useChangeRole, changeRoleSchema, USERS_TEXT } from "@/features/users";

import type { User, ChangeRoleInput } from "@/features/users";

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

      toast.success(USERS_TEXT.success_dialog.success_role);

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
        {isPending ? USERS_TEXT.loading : USERS_TEXT.actions.change_role}
      </Button>
    </form>
  );
}
