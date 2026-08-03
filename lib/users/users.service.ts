import bcrypt from "bcryptjs";

import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/get-current-user";
import { canManageRole, hasMinRole, getManageableRoles, ROLES } from "@/lib/auth/permissions";
import { generateTemporaryPassword } from "@/lib/utils/password";

import {
  ForbiddenError,
  NotFoundError,
  ValidationError,
} from "@/lib/errors/errors";

import type {
  User,
  CreateUserInput,
  ChangeRoleInput,
  UpdateUserStatusInput,
  CreateUserResponse,
} from "@/features/users/types";

type RoleRow = {
  id: string;
};

type UserWithRole = {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  is_active: boolean;
  role: User["role"];
};

export class UsersService {
  private static async requireCurrentUser() {
    const currentUser = await getCurrentUser();

    if (!currentUser) {
      throw new ForbiddenError();
    }

    return currentUser;
  }

  private static async getRoleId(role: string): Promise<string> {
    const roles = (await sql`
      SELECT id
      FROM roles
      WHERE code = ${role}
      LIMIT 1
    `) as RoleRow[];

    if (!roles.length) {
      throw new ValidationError("Роль не знайдена");
    }

    return roles[0].id;
  }

  private static async getUserWithRole(id: string): Promise<UserWithRole> {
    const users = (await sql`
    SELECT
      u.id,
      u.email,
      u.first_name,
      u.last_name,
      u.is_active,
      r.code AS role
    FROM users u
    JOIN user_roles ur
      ON ur.user_id = u.id
    JOIN roles r
      ON r.id = ur.role_id
    WHERE
      u.id = ${id}
      AND u.deleted_at IS NULL
    LIMIT 1
  `) as UserWithRole[];

    if (!users.length) {
      throw new NotFoundError("Користувача не знайдено");
    }

    return users[0];
  }

  static async getUsers(): Promise<User[]> {
    const currentUser = await this.requireCurrentUser();

    const manageableRoles = getManageableRoles(currentUser.role);

    const users = (await sql`
    SELECT
      u.id,
      u.email,
      u.first_name,
      u.last_name,
      u.is_active,
      r.code AS role
    FROM users u
    JOIN user_roles ur
      ON ur.user_id = u.id
    JOIN roles r
      ON r.id = ur.role_id
    WHERE u.deleted_at IS NULL
    ORDER BY u.first_name, u.last_name
  `) as User[];

    return users.filter(
      (user) =>
        user.id === currentUser.id || manageableRoles.includes(user.role),
    );
  }

  static async createUser(data: CreateUserInput): Promise<CreateUserResponse> {
    const currentUser = await this.requireCurrentUser();

    if (!canManageRole(currentUser.role, data.role)) {
      throw new ForbiddenError(
        "Недостатньо прав для створення користувача з цією роллю",
      );
    }

    const existing = (await sql`
    SELECT id
    FROM users
    WHERE email = ${data.email}
    LIMIT 1
  `) as { id: string }[];

    if (existing.length) {
      throw new ValidationError("Користувач з таким email вже існує");
    }

    const temporaryPassword = generateTemporaryPassword();
    const passwordHash = await bcrypt.hash(temporaryPassword, 12);

    const users = (await sql`
    INSERT INTO users (
      email,
      first_name,
      last_name,
      password_hash,
      is_active,
      created_by
    )
    VALUES (
      ${data.email},
      ${data.first_name},
      ${data.last_name},
      ${passwordHash},
      true,
      ${currentUser.id}
    )
    RETURNING
      id,
      email,
      first_name,
      last_name,
      is_active
  `) as Omit<User, "role">[];

    const user = users[0];

    const roleId = await this.getRoleId(data.role);

    await sql`
    INSERT INTO user_roles (
      user_id,
      role_id
    )
    VALUES (
      ${user.id},
      ${roleId}
    )
  `;

    await sql`
    INSERT INTO password_history (
      user_id,
      password_hash
    )
    VALUES (
      ${user.id},
      ${passwordHash}
    )
  `;

    await sql`
    INSERT INTO password_resets (
      user_id,
      token,
      expires_at
    )
    VALUES (
      ${user.id},
      ${crypto.randomUUID()},
      NOW() + INTERVAL '365 days'
    )
  `;

    return {
      user: {
        ...user,
        role: data.role,
      },
      temporaryPassword,
    };
  }

  static async changeRole(id: string, data: ChangeRoleInput): Promise<User> {
    const currentUser = await this.requireCurrentUser();

    if (!canManageRole(currentUser.role, data.role)) {
      throw new ForbiddenError();
    }

    await this.getUserWithRole(id);

    const roleId = await this.getRoleId(data.role);

    await sql`
    UPDATE user_roles
    SET role_id = ${roleId}
    WHERE user_id = ${id}
  `;

    return this.getUserWithRole(id);
  }

  static async updateUserStatus(
    id: string,
    data: UpdateUserStatusInput,
  ): Promise<User> {
    const currentUser = await this.requireCurrentUser();

    if (!hasMinRole(currentUser.role, ROLES.MANAGER)) {
      throw new ForbiddenError();
    }

    const targetUser = await this.getUserWithRole(id);

    if (!canManageRole(currentUser.role, targetUser.role)) {
      throw new ForbiddenError(
        "Недостатньо прав для зміни статусу цього користувача",
      );
    }

    await sql`
    UPDATE users
    SET
      is_active = ${data.is_active},
      updated_at = NOW()
    WHERE id = ${id}
  `;

    return this.getUserWithRole(id);
  }
}
