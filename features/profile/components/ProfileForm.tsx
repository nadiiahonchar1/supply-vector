"use client";

import { useEffect } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import toast from "react-hot-toast";

import { useAuth } from "@/features/auth/context/useAuth";

import { useProfile } from "../api/hooks/useProfile";
import { useUpdateProfile } from "../api/hooks/useUpdateProfile";

import {
  profileSchema,
  type ProfileSchema,
} from "../validation/profile.schema";

export function ProfileForm() {
  const { profile, setProfile, isLoading } = useProfile();
  const { updateProfile } = useUpdateProfile();
  const { setUser } = useAuth();

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isSubmitting },
  } = useForm<ProfileSchema>({
    resolver: zodResolver(profileSchema),
  });

  useEffect(() => {
    if (!profile) return;

    reset({
      first_name: profile.first_name,
      last_name: profile.last_name,
    });
  }, [profile, reset]);

  async function onSubmit(data: ProfileSchema) {
    const updated = await updateProfile(data);

    setProfile(updated);
    setUser(updated as never);

    toast.success("Profile updated");
  }

  if (isLoading) {
    return <div>Loading...</div>;
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
      <div>
        <label>First name</label>

        <input
          {...register("first_name")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">{errors.first_name?.message}</p>
      </div>

      <div>
        <label>Last name</label>

        <input
          {...register("last_name")}
          className="w-full rounded-md border p-2"
        />

        <p className="text-sm text-red-500">{errors.last_name?.message}</p>
      </div>

      <button
        type="submit"
        disabled={isSubmitting}
        className="rounded-md bg-primary px-4 py-2 text-primary-foreground"
      >
        Save
      </button>
    </form>
  );
}
