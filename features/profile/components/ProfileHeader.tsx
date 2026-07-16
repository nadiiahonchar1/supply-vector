"use client";

import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";

import { getUserInitials } from "@/features/auth/utils/user";

import type { Profile } from "../types";

type ProfileHeaderProps = {
  profile: Profile;
};

export function ProfileHeader({ profile }: ProfileHeaderProps) {
  return (
    <div className="mb-8 flex items-center gap-6">
      <Avatar className="h-20 w-20">
        <AvatarFallback className="text-xl">
          {getUserInitials(profile)}
        </AvatarFallback>
      </Avatar>

      <div className="space-y-2">
        <h1 className="text-3xl font-bold">
          {profile.first_name} {profile.last_name}
        </h1>

        <p className="text-muted-foreground">{profile.email}</p>

        <Badge variant="secondary">{profile.role}</Badge>
      </div>
    </div>
  );
}
