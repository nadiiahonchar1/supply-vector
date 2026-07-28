"use client";

import { useForm } from "react-hook-form";
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

type Props = {
  onSuccess: (temporaryPassword: string) => void;
};

export function CreateUserForm({ onSuccess }: Props) {
  const {
    register,
    handleSubmit,
    setValue,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<CreateUserInput>({
    resolver: zodResolver(createUserSchema),
    defaultValues: {
      email: "",
      first_name: "",
      last_name: "",
      role: ROLES.OPERATOR,
    },
  });

  const role = watch("role");

  const onSubmit = async (data: CreateUserInput) => {
    console.log(data);

    // useCreateUser()
    // const result = await mutateAsync(data);
    // onSuccess(result.temporaryPassword);

    onSuccess("тимчасовий-пароль");
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
        <label>Роль</label>

        <Select
          value={role}
          onValueChange={(value) =>
            setValue("role", value as CreateUserInput["role"])
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

      <Button type="submit" className="w-full" disabled={isSubmitting}>
        {USERS_TEXT.create}
      </Button>
    </form>
  );
}
