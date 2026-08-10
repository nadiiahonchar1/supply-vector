import bcrypt from "bcryptjs";

import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/server";
import {
  canManageRole,
  hasMinRole,
  getVisibleRoles,
  ROLES,
  RolePolicy,
} from "@/lib/auth";
import { generateTemporaryPassword } from "@/lib/utils";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type {
  User,
  CreateUserInput,
  ChangeRoleInput,
  UpdateUserStatusInput,
  CreateUserResponse,
  UsersQuery,
  PaginatedUsersResponse,
} from "@/features/users";

import { USERS_TEXT } from "@/features/users";

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
      throw new ValidationError(USERS_TEXT.error.empty_role);
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
      throw new NotFoundError(USERS_TEXT.error.empty_user);
    }

    return users[0];
  }

  static async getUsers({
    page = 1,
    limit = 20,
  }: UsersQuery): Promise<PaginatedUsersResponse> {
    const currentUser = await this.requireCurrentUser();

    const visibleRoles = getVisibleRoles(currentUser.role);

    const offset = (page - 1) * limit;

    const totalRows = (await sql`
    SELECT COUNT(*)::int AS total
    FROM users u
    JOIN user_roles ur
      ON ur.user_id = u.id
    JOIN roles r
      ON r.id = ur.role_id
    WHERE
      u.deleted_at IS NULL
      AND r.code = ANY(${visibleRoles})
  `) as { total: number }[];

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
      u.deleted_at IS NULL
      AND r.code = ANY(${visibleRoles})
    ORDER BY
      CASE r.code
        WHEN 'superadmin' THEN 1
        WHEN 'admin' THEN 2
        WHEN 'manager' THEN 3
        WHEN 'operator' THEN 4
      END,
      u.last_name,
      u.first_name
    LIMIT ${limit}
    OFFSET ${offset}
  `) as User[];

    const total = totalRows[0].total;

    return {
      users,
      total,
      page,
      totalPages: Math.ceil(total / limit),
    };
  }

  static async createUser(data: CreateUserInput): Promise<CreateUserResponse> {
    const currentUser = await this.requireCurrentUser();

    if (!canManageRole(currentUser.role, data.role)) {
      throw new ForbiddenError(USERS_TEXT.error.forbidded_permission_create);
    }

    const existing = (await sql`
    SELECT id
    FROM users
    WHERE email = ${data.email}
    LIMIT 1
  `) as { id: string }[];

    if (existing.length) {
      throw new ValidationError(USERS_TEXT.error.email);
    }

    const roleId = await this.getRoleId(data.role);

    const temporaryPassword = generateTemporaryPassword();
    const passwordHash = await bcrypt.hash(temporaryPassword, 12);

    const userId = crypto.randomUUID();

    const [insertedUsers] = (await sql.transaction([
      sql`
      INSERT INTO users (
        id,
        email,
        first_name,
        last_name,
        password_hash,
        is_active,
        created_by
      )
      VALUES (
        ${userId},
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
    `,
      sql`
      INSERT INTO user_roles (
        user_id,
        role_id
      )
      VALUES (
        ${userId},
        ${roleId}
      )
    `,
      sql`
      INSERT INTO password_history (
        user_id,
        password_hash
      )
      VALUES (
        ${userId},
        ${passwordHash}
      )
    `,
      sql`
      INSERT INTO password_resets (
        user_id,
        token,
        expires_at
      )
      VALUES (
        ${userId},
        ${crypto.randomUUID()},
        NOW() + INTERVAL '365 days'
      )
    `,
    ])) as [Omit<User, "role">[], unknown, unknown, unknown];

    const user = insertedUsers[0];

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

    const targetUser = await this.getUserWithRole(id);

    if (
      !RolePolicy.canChangeUserRole(currentUser, targetUser.role, data.role)
    ) {
      throw new ForbiddenError();
    }

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
      throw new ForbiddenError(USERS_TEXT.error.forbidden_permission_change);
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
