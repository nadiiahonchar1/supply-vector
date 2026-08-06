"use client";

import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Badge,
} from "@/components/ui";
import { PROFILE_TEXT } from "../constants/profile-text";
import type { Profile } from "../types";

type ProfileInfoCardProps = {
  profile: Profile;
};

export function ProfileInfoCard({ profile }: ProfileInfoCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{PROFILE_TEXT.title}</CardTitle>
      </CardHeader>

      <CardContent className="space-y-6">
        <div>
          <p className="text-sm text-muted-foreground">
            {PROFILE_TEXT.table.status}
          </p>

          <Badge variant={profile.is_active ? "default" : "destructive"}>
            {profile.is_active
              ? PROFILE_TEXT.status.active
              : PROFILE_TEXT.status.inactive}
          </Badge>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">
            {PROFILE_TEXT.table.role}
          </p>

          <p className="font-medium capitalize">{profile.role}</p>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">
            {PROFILE_TEXT.table.email}
          </p>

          <p>{profile.email}</p>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">
            {PROFILE_TEXT.table.user_id}
          </p>

          <p className="break-all text-xs">{profile.id}</p>
        </div>
      </CardContent>
    </Card>
  );
}
