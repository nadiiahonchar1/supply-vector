import { ProfileForm } from "./ProfileForm";
import { SecurityForm } from "./SecurityForm";

export function ProfilePage() {
  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-8">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">My profile</h1>

        <p className="mt-2 text-muted-foreground">
          Manage your personal information and account security.
        </p>
      </div>

      <div className="grid gap-8 xl:grid-cols-[2fr_1fr]">
        <ProfileForm />

        <SecurityForm />
      </div>
    </div>
  );
}
