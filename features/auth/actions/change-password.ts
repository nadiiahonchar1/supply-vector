"use server";

import { sql } from "@/db";

import { requireUser } from "@/lib/auth/auth-service";
import { hashPassword, verifyPassword } from "@/lib/auth/password";

type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};

export async function changePasswordAction({
  currentPassword,
  newPassword,
}: ChangePasswordInput) {
  const currentUser = await requireUser();

  const users = await sql`
    SELECT
      password_hash
    FROM users
    WHERE id = ${currentUser.id}
    LIMIT 1
  `;

  const user = users[0];

  if (!user) {
    throw new Error("User not found");
  }

  const isValid = await verifyPassword(currentPassword, user.password_hash);

  if (!isValid) {
    throw new Error("Current password is incorrect");
  }

  const isSamePassword = await verifyPassword(newPassword, user.password_hash);

  if (isSamePassword) {
    throw new Error("New password must be different from current password");
  }

  const newPasswordHash = await hashPassword(newPassword);

  await sql`
    UPDATE users
    SET
      password_hash = ${newPasswordHash},
      updated_at = NOW()
    WHERE id = ${currentUser.id}
  `;

  await sql`
    INSERT INTO password_history (
      user_id,
      password_hash
    )
    VALUES (
      ${currentUser.id},
      ${newPasswordHash}
    )
  `;

  return {
    success: true,
  };
}
