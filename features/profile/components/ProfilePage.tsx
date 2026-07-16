"use client";

import { ProfileHeader } from "./ProfileHeader";
import { ProfileInfoCard } from "./ProfileInfoCard";
import { ProfileForm } from "./ProfileForm";
import { SecurityForm } from "./SecurityForm";

import type { Profile } from "../types";

type ProfilePageProps = {
  profile: Profile;
};

export function ProfilePage({ profile }: ProfilePageProps) {
  return (
    <div className="space-y-8">
      <ProfileHeader profile={profile} />

      <div className="grid gap-8 lg:grid-cols-3">
        <ProfileInfoCard profile={profile} />

        <div className="space-y-8 lg:col-span-2">
          <ProfileForm />

          <SecurityForm />
        </div>
      </div>
    </div>
  );
}
