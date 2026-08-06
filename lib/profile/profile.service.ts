import bcrypt from "bcryptjs";

import { sql } from "@/db";
import { getCurrentUser } from "@/lib/auth/get-current-user";
import type { CurrentUser } from "@/features/auth/types";
import {
  UnauthorizedError,
  ValidationError,
  NotFoundError,
} from "@/lib/errors";
import { PROFILE_TEXT } from "@/features/profile/constants/profile-text";

export type UpdateProfileDto = {
  first_name: string;
  last_name: string;
};

export type ChangePasswordDto = {
  currentPassword: string;
  newPassword: string;
};

export class ProfileService {
  static async getProfile(): Promise<CurrentUser> {
    const user = await getCurrentUser();

    if (!user) {
      throw new UnauthorizedError();
    }

    return user;
  }

  static async updateProfile(data: UpdateProfileDto): Promise<CurrentUser> {
    const currentUser = await this.getProfile();

    const users = (await sql`
      UPDATE users
      SET
        first_name = ${data.first_name},
        last_name = ${data.last_name}
      WHERE id = ${currentUser.id}
      RETURNING
        id,
        email,
        first_name,
        last_name,
        is_active
    `) as Omit<CurrentUser, "role">[];

    return {
      ...users[0],
      role: currentUser.role,
    };
  }

  static async changePassword(data: ChangePasswordDto): Promise<void> {
    const currentUser = await this.getProfile();

    const users = (await sql`
      SELECT password_hash
      FROM users
      WHERE id = ${currentUser.id}
      LIMIT 1
    `) as { password_hash: string }[];

    const currentPasswordHash = users[0]?.password_hash;

    if (!currentPasswordHash) {
      throw new NotFoundError(PROFILE_TEXT.error.not_found);
    }

    const isCurrentPasswordValid = await bcrypt.compare(
      data.currentPassword,
      currentPasswordHash,
    );

    if (!isCurrentPasswordValid) {
      throw new ValidationError(PROFILE_TEXT.error.wrong);
    }

    const sameAsCurrent = await bcrypt.compare(
      data.newPassword,
      currentPasswordHash,
    );

    if (sameAsCurrent) {
      throw new ValidationError(
        PROFILE_TEXT.error.not_new
      );
    }

    const previousPasswords = (await sql`
      SELECT password_hash
      FROM password_history
      WHERE user_id = ${currentUser.id}
      ORDER BY created_at DESC
      LIMIT 5
    `) as { password_hash: string }[];

    for (const previous of previousPasswords) {
      const alreadyUsed = await bcrypt.compare(
        data.newPassword,
        previous.password_hash,
      );

      if (alreadyUsed) {
        throw new ValidationError(
          PROFILE_TEXT.error.in_top_five
        );
      }
    }

    const newPasswordHash = await bcrypt.hash(data.newPassword, 12);

    await sql`
      UPDATE users
      SET password_hash = ${newPasswordHash}
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

    await sql`
      UPDATE password_resets
      SET used_at = NOW()
      WHERE user_id = ${currentUser.id}
        AND used_at IS NULL
    `;
  }
}
