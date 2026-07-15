import { z } from "zod";

export const changePasswordSchema = z.object({
  currentPassword: z.string().min(8, "Current password is required"),

  newPassword: z
    .string()
    .min(8, "Password must contain at least 8 characters")
    .max(64, "Password is too long")
    .regex(/[a-z]/, "Password must contain a lowercase letter")
    .regex(/[A-Z]/, "Password must contain an uppercase letter")
    .regex(/[0-9]/, "Password must contain a number"),
});

export type ChangePasswordInput = z.infer<typeof changePasswordSchema>;
