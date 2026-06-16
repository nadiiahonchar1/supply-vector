import "dotenv/config";

import { sql } from "@/db";
import { hashPassword } from "@/lib/auth/password";

async function addManager() {
  const passwordHash = await hashPassword("manager123");

  const existingUser = await sql`
    SELECT id
    FROM users
    WHERE email = 'manager@test.com'
  `;

  if (existingUser.length) {
    console.log("User already exists");
    return;
  }

  const users = await sql`
    INSERT INTO users (
      email,
      password_hash,
      first_name,
      last_name,
      is_active
    )
    VALUES (
      'manager@test.com',
      ${passwordHash},
      'Manager',
      'User',
      true
    )
    RETURNING id;
  `;

  const userId = users[0].id;

  const roles = await sql`
    SELECT id
    FROM roles
    WHERE code = 'manager'
  `;

  if (!roles.length) {
    throw new Error("Role 'manager' not found");
  }

  await sql`
    INSERT INTO user_roles (
      user_id,
      role_id
    )
    VALUES (
      ${userId},
      ${roles[0].id}
    )
  `;

  console.log("Manager created successfully");
}

addManager()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
