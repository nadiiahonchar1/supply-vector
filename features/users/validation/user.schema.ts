import { z } from "zod";

import { ROLES } from "@/lib/auth/permissions";

export const createUserSchema = z.object({
  email: z.email("Введіть коректний email"),

  first_name: z
    .string()
    .trim()
    .min(2, "Ім'я повинно містити мінімум 2 символи")
    .max(50),

  last_name: z
    .string()
    .trim()
    .min(2, "Прізвище повинно містити мінімум 2 символи")
    .max(50),

  role: z.enum([ROLES.SUPER_ADMIN, ROLES.ADMIN, ROLES.MANAGER, ROLES.OPERATOR]),
});

export const changeRoleSchema = z.object({
  role: z.enum([ROLES.SUPER_ADMIN, ROLES.ADMIN, ROLES.MANAGER, ROLES.OPERATOR]),
});

export const updateUserStatusSchema = z.object({
  is_active: z.boolean(),
});
