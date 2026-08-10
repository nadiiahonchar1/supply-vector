import { ProfilePage } from "@/features/profile/components/ProfilePage";

import { ProfileService } from "@/lib/profile/profile.service";

type PageProps = {
  searchParams: Promise<{ forceChange?: string }>;
};

export default async function Page({ searchParams }: PageProps) {
  const profile = await ProfileService.getProfile();
  const { forceChange } = await searchParams;

  return (
    <ProfilePage profile={profile} forcePasswordChange={forceChange === "1"} />
  );
}
