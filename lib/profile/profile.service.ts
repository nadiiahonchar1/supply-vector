import bcrypt from "bcryptjs";

import { sql } from "@/db";
import { getCurrentUser } from "@/lib/auth/get-current-user";
import type { CurrentUser } from "@/features/auth/types";
import {
  UnauthorizedError,
  ValidationError,
  NotFoundError,
} from "@/lib/errors/errors";

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

    const passwordHash = users[0]?.password_hash;

    if (!passwordHash) {
      throw new NotFoundError("User not found");
    }

    const isValid = await bcrypt.compare(data.currentPassword, passwordHash);

    if (!isValid) {
      throw new ValidationError("Current password is incorrect");
    }

    const hash = await bcrypt.hash(data.newPassword, 12);

    await sql`
      UPDATE users
      SET password_hash = ${hash}
      WHERE id = ${currentUser.id}
    `;
  }
}
