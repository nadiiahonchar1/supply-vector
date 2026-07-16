import { ProfilePage } from "@/features/profile/components/ProfilePage";

import { ProfileService } from "@/lib/profile/profile.service";

export default async function Page() {
  const profile = await ProfileService.getProfile();

  return <ProfilePage profile={profile} />;
}
