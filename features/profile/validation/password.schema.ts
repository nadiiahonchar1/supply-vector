import { z } from "zod";

export const changePasswordFormSchema = z
  .object({
    currentPassword: z.string().min(1, "Введіть поточний пароль"),

    newPassword: z.string().min(8, "Пароль повинен містити мінімум 8 символів"),

    confirmPassword: z.string().min(1, "Підтвердіть пароль"),
  })
  .refine((data) => data.newPassword === data.confirmPassword, {
    path: ["confirmPassword"],
    message: "Паролі не співпадають",
  });

export const changePasswordSchema = z.object({
  currentPassword: z.string().min(1, "Введіть поточний пароль"),

  newPassword: z.string().min(8, "Пароль повинен містити мінімум 8 символів"),
});

export type ChangePasswordFormValues = z.infer<typeof changePasswordFormSchema>;
