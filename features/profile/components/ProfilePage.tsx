"use client";

import {
  ProfileHeader,
  ProfileInfoCard,
  ProfileForm,
  SecurityForm,
} from "../components";
import { PROFILE_TEXT } from "../constants/profile-text";
import type { Profile } from "../types";

type ProfilePageProps = {
  profile: Profile;
  forcePasswordChange?: boolean;
};

export function ProfilePage({
  profile,
  forcePasswordChange = false,
}: ProfilePageProps) {
  return (
    <div className="space-y-8">
      {forcePasswordChange && (
        <div className="rounded-md border border-yellow-500/50 bg-yellow-50 p-4 text-sm text-yellow-900">
          {PROFILE_TEXT.security_dialog.force_change_notice}
        </div>
      )}

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
