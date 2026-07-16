"use client";

import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";

import { useAuth } from "@/features/auth/context/useAuth";
import { useUpdateProfile } from "../api/hooks/useUpdateProfile";

import {
  updateProfileSchema,
  type UpdateProfileInput,
} from "../validation/profile.schema";

export function ProfileForm() {
  const { user, setUser } = useAuth();
  const { updateProfile } = useUpdateProfile();

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<UpdateProfileInput>({
    resolver: zodResolver(updateProfileSchema),
    defaultValues: {
      first_name: "",
      last_name: "",
    },
  });

  useEffect(() => {
    if (!user) return;

    reset({
      first_name: user.first_name,
      last_name: user.last_name,
    });
  }, [user, reset]);

  async function onSubmit(data: UpdateProfileInput) {
    const updatedUser = await updateProfile(data);

    setUser(updatedUser);

    toast.success("Profile updated");
  }

  if (!user) {
    return <div>Loading...</div>;
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
      <div>
        <label className="mb-2 block text-sm font-medium">First name</label>

        <input
          {...register("first_name")}
          className="w-full rounded-md border p-2"
        />

        {errors.first_name && (
          <p className="mt-1 text-sm text-red-500">
            {errors.first_name.message}
          </p>
        )}
      </div>

      <div>
        <label className="mb-2 block text-sm font-medium">Last name</label>

        <input
          {...register("last_name")}
          className="w-full rounded-md border p-2"
        />

        {errors.last_name && (
          <p className="mt-1 text-sm text-red-500">
            {errors.last_name.message}
          </p>
        )}
      </div>

      <button
        type="submit"
        disabled={isSubmitting}
        className="rounded-md bg-primary px-4 py-2 text-primary-foreground disabled:opacity-50"
      >
        {isSubmitting ? "Saving..." : "Save changes"}
      </button>
    </form>
  );
}
