"use client";

import { useRouter } from "next/navigation";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";
import { useChangePassword } from "../api/hooks";
import { changePasswordFormSchema } from "../validation/password.schema";
import type { ChangePasswordFormValues } from "../types";
import { PROFILE_TEXT } from "../constants/profile-text";

export function SecurityForm() {
  const router = useRouter();
  const { changePassword } = useChangePassword();

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<ChangePasswordFormValues>({
    resolver: zodResolver(changePasswordFormSchema),
  });

  async function onSubmit(data: ChangePasswordFormValues) {
    await changePassword({
      currentPassword: data.currentPassword,
      newPassword: data.newPassword,
    });

    reset();

    toast.success(PROFILE_TEXT.toast_masages.succes_change);

    router.replace("/profile");
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
      <div>
        <label>{PROFILE_TEXT.security_dialog.current_password}</label>

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
        <label>{PROFILE_TEXT.security_dialog.new_password}</label>

        <input
          type="password"
          {...register("newPassword")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">{errors.newPassword?.message}</p>
      </div>

      <div>
        <label>{PROFILE_TEXT.security_dialog.confirm_password}</label>

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
        {PROFILE_TEXT.security_dialog.change}
      </button>
    </form>
  );
}
