"use client";

import { useForm, useWatch } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

import { ROLES } from "@/lib/auth/permissions";

import { USERS_TEXT } from "../../constants/users-text";
import { createUserSchema } from "../../validation/user.schema";

import type { CreateUserInput } from "../../types";

import { useCreateUser } from "../../api";

type Props = {
  onSuccess: (temporaryPassword: string) => void;
};

export function CreateUserForm({ onSuccess }: Props) {
  const {
    register,
    handleSubmit,
    setValue,
    reset,
    control,
    formState: { errors },
  } = useForm<CreateUserInput>({
    resolver: zodResolver(createUserSchema),

    defaultValues: {
      email: "",
      first_name: "",
      last_name: "",
      role: ROLES.OPERATOR,
    },
  });

  const { mutateAsync, isPending, error } = useCreateUser();

  const role = useWatch({
    control,
    name: "role",
  });

  const onSubmit = async (data: CreateUserInput) => {
    try {
      const result = await mutateAsync(data);
      console.log("SUCCESS");

      reset();

      onSuccess(result.temporaryPassword);
    } catch (error) {
      console.error(error);
    }
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-5">
      <div className="space-y-2">
        <label>{USERS_TEXT.table.firstName}</label>

        <Input {...register("first_name")} />

        {errors.first_name && (
          <p className="text-sm text-destructive">
            {errors.first_name.message}
          </p>
        )}
      </div>

      <div className="space-y-2">
        <label>{USERS_TEXT.table.lastName}</label>

        <Input {...register("last_name")} />

        {errors.last_name && (
          <p className="text-sm text-destructive">{errors.last_name.message}</p>
        )}
      </div>

      <div className="space-y-2">
        <label>{USERS_TEXT.table.email}</label>

        <Input type="email" {...register("email")} />

        {errors.email && (
          <p className="text-sm text-destructive">{errors.email.message}</p>
        )}
      </div>

      <div className="space-y-2">
        <label>{USERS_TEXT.table.role}</label>

        <Select
          value={role}
          onValueChange={(value) =>
            setValue("role", value as CreateUserInput["role"], {
              shouldValidate: true,
            })
          }
        >
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>

          <SelectContent>
            <SelectItem value={ROLES.ADMIN}>{USERS_TEXT.role.admin}</SelectItem>

            <SelectItem value={ROLES.MANAGER}>
              {USERS_TEXT.role.manager}
            </SelectItem>

            <SelectItem value={ROLES.OPERATOR}>
              {USERS_TEXT.role.operator}
            </SelectItem>
          </SelectContent>
        </Select>

        {errors.role && (
          <p className="text-sm text-destructive">{errors.role.message}</p>
        )}
      </div>

      {error && <p className="text-sm text-destructive">{error.message}</p>}

      <Button type="submit" className="w-full" disabled={isPending}>
        {isPending ? USERS_TEXT.loading : USERS_TEXT.create}
      </Button>
    </form>
  );
}
