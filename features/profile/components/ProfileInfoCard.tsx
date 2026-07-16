"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

import { Badge } from "@/components/ui/badge";

import type { Profile } from "../types";

type ProfileInfoCardProps = {
  profile: Profile;
};

export function ProfileInfoCard({ profile }: ProfileInfoCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Account</CardTitle>
      </CardHeader>

      <CardContent className="space-y-6">
        <div>
          <p className="text-sm text-muted-foreground">Status</p>

          <Badge variant={profile.is_active ? "default" : "destructive"}>
            {profile.is_active ? "Active" : "Inactive"}
          </Badge>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">Role</p>

          <p className="font-medium capitalize">{profile.role}</p>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">Email</p>

          <p>{profile.email}</p>
        </div>

        <div>
          <p className="text-sm text-muted-foreground">User ID</p>

          <p className="break-all text-xs">{profile.id}</p>
        </div>
      </CardContent>
    </Card>
  );
}
