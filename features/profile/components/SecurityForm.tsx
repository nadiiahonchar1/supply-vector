"use client";

import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";

import { useChangePassword } from "../api/hooks/useChangePassword";

import { changePasswordSchema } from "../validation/password.schema";
import type { ChangePasswordFormValues } from "../types";

export function SecurityForm() {
  const { changePassword } = useChangePassword();

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<ChangePasswordFormValues>({
    resolver: zodResolver(changePasswordSchema),
  });

  async function onSubmit(data: ChangePasswordFormValues) {
    await changePassword({
      currentPassword: data.currentPassword,
      newPassword: data.newPassword,
    });

    reset();

    toast.success("Password changed");
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
      <div>
        <label>Current password</label>

        <input
          type="password"
          {...register("currentPassword")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">
          {errors.currentPassword?.message}
        </p>
      </div>

      <div>
        <label>New password</label>

        <input
          type="password"
          {...register("newPassword")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">{errors.newPassword?.message}</p>
      </div>

      <div>
        <label>Confirm password</label>

        <input
          type="password"
          {...register("confirmPassword")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">
          {errors.confirmPassword?.message}
        </p>
      </div>

      <button
        type="submit"
        disabled={isSubmitting}
        className="rounded-md bg-primary px-4 py-2 text-primary-foreground"
      >
        Change password
      </button>
    </form>
  );
}
