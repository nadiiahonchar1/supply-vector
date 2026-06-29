import { sql } from "@/db";
import { hashPassword, verifyPassword } from "@/lib/auth/password";
import { Role, canManageRole } from "@/lib/auth/permissions";
import { UserPolicy } from "@/lib/auth/policies";

// =====================================================
// TYPES
// =====================================================

type CurrentUser = {
  id: string;
  role: Role;
};

type CreateUserInput = {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  role: Role;
  storeIds?: string[];
};

type ChangePasswordInput = {
  currentPassword: string;
  newPassword: string;
};

// =====================================================
// SERVICE
// =====================================================

export class UserManagementService {
  // -------------------------------------
  // CREATE USER
  // -------------------------------------
  static async createUser(currentUser: CurrentUser, input: CreateUserInput) {
    if (!canManageRole(currentUser.role, input.role)) {
      throw new Error("Forbidden");
    }

    const existing = await sql`
      SELECT id FROM users WHERE email = ${input.email} LIMIT 1
    `;

    if (existing.length) {
      throw new Error("User already exists");
    }

    const passwordHash = await hashPassword(input.password);

    const users = await sql`
      INSERT INTO users (
        email,
        password_hash,
        first_name,
        last_name,
        is_active,
        created_by
      )
      VALUES (
        ${input.email},
        ${passwordHash},
        ${input.firstName},
        ${input.lastName},
        true,
        ${currentUser.id}
      )
      RETURNING id
    `;

    const userId = users[0].id;

    const roleRow = await sql`
      SELECT id FROM roles WHERE code = ${input.role} LIMIT 1
    `;

    if (!roleRow.length) {
      throw new Error("Role not found");
    }

    await sql`
      INSERT INTO user_roles (user_id, role_id)
      VALUES (${userId}, ${roleRow[0].id})
    `;

    if (input.storeIds?.length) {
      for (const storeId of input.storeIds) {
        await sql`
          INSERT INTO user_stores (user_id, store_id)
          VALUES (${userId}, ${storeId})
        `;
      }
    }

    return { userId };
  }

  // -------------------------------------
  // DELETE USER
  // -------------------------------------
  static async deleteUser(currentUser: CurrentUser, targetUserId: string) {
    if (currentUser.id === targetUserId) {
      throw new Error("You cannot delete yourself");
    }

    const targetRoleRow = await sql`
    SELECT r.code
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = ${targetUserId}
    LIMIT 1
  `;

    if (!targetRoleRow.length) {
      throw new Error("Target role not found");
    }

    const targetRole = targetRoleRow[0].code;

    const { UserPolicy } = await import("@/lib/auth/policies");

    if (!UserPolicy.canDeleteUser(currentUser.role, targetRole)) {
      throw new Error("Forbidden");
    }

    const result = await sql`
    UPDATE users
    SET
      is_active = false,
      deleted_at = NOW(),
      deleted_by = ${currentUser.id},
      updated_at = NOW()
    WHERE id = ${targetUserId}
      AND is_active = true
    RETURNING id
  `;

    if (!result.length) {
      throw new Error("User not found");
    }

    return { success: true };
  }
  // -------------------------------------
  // CHANGE PASSWORD
  // -------------------------------------
  static async changePassword(
    currentUser: CurrentUser,
    input: ChangePasswordInput,
  ) {
    const userRows = await sql`
      SELECT password_hash
      FROM users
      WHERE id = ${currentUser.id}
      LIMIT 1
    `;

    const user = userRows[0];

    if (!user) {
      throw new Error("User not found");
    }

    const isValid = await verifyPassword(
      input.currentPassword,
      user.password_hash,
    );

    if (!isValid) {
      throw new Error("Current password is incorrect");
    }

    const isSame = await verifyPassword(input.newPassword, user.password_hash);

    if (isSame) {
      throw new Error("New password must be different");
    }

    const newHash = await hashPassword(input.newPassword);

    await sql`
      UPDATE users
      SET password_hash = ${newHash}, updated_at = NOW()
      WHERE id = ${currentUser.id}
    `;

    await sql`
      INSERT INTO password_history (user_id, password_hash)
      VALUES (${currentUser.id}, ${newHash})
    `;

    return { success: true };
  }

  static async listUsers(currentUser: CurrentUser) {
    if (!UserPolicy.canViewUsers(currentUser.role)) {
      throw new Error("Forbidden");
    }

    return await sql`
    SELECT
      id,
      email,
      first_name,
      last_name,
      is_active,
      created_at
    FROM users
    WHERE is_active = true
    ORDER BY created_at DESC
  `;
  }

  static async getUserById(currentUser: CurrentUser, userId: string) {
    const user = await sql`
    SELECT
      id,
      email,
      first_name,
      last_name,
      is_active,
      created_at
    FROM users
    WHERE id = ${userId}
      AND is_active = true
    LIMIT 1
  `;

    if (!user.length) {
      throw new Error("User not found");
    }

    return user[0];
  }
}
