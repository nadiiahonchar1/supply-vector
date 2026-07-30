import { z } from "zod";

export const changePasswordSchema = z.object({
  currentPassword: z.string().min(1, "Введіть поточний пароль"),

  newPassword: z.string().min(8, "Пароль повинен містити мінімум 8 символів"),
});

export type ChangePasswordInput = z.infer<typeof changePasswordSchema>;