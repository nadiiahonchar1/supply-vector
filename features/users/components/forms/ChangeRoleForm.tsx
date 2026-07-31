"use client";

import { useForm, useWatch } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Button } from "@/components/ui/button";

import { ROLES } from "@/lib/auth/permissions";

import { USERS_TEXT } from "../../constants/users-text";
import { changeRoleSchema } from "../../validation/user.schema";

import { useChangeRole } from "../../api";

import type { User, ChangeRoleInput } from "../../types";

type Props = {
  user: User;
  onSuccess: () => void;
};

const ROLE_OPTIONS = Object.values(ROLES).map((role) => ({
  value: role,
  label: USERS_TEXT.role[role],
}));

export function ChangeRoleForm({ user, onSuccess }: Props) {
  const {
    control,
    setValue,
    handleSubmit,
    formState: { errors },
  } = useForm<ChangeRoleInput>({
    resolver: zodResolver(changeRoleSchema),

    defaultValues: {
      role: user.role,
    },
  });

  const role = useWatch({
    control,
    name: "role",
  });

  const { mutateAsync, isPending, error } = useChangeRole();

  const onSubmit = async (data: ChangeRoleInput) => {
    await mutateAsync({
      userId: user.id,
      role: data.role,
    });

    toast.success("Роль користувача успішно змінена");

    onSuccess();
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-5">
      <div className="space-y-2">
        <label>{USERS_TEXT.table.role}</label>

        <Select
          value={role}
          onValueChange={(value) =>
            setValue("role", value as ChangeRoleInput["role"], {
              shouldValidate: true,
            })
          }
        >
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>

          <SelectContent>
            {ROLE_OPTIONS.map((roleOption) => (
              <SelectItem key={roleOption.value} value={roleOption.value}>
                {roleOption.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

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
