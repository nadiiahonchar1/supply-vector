import { z } from "zod";
import { PROFILE_TEXT } from "../constants/profile-text";

export const changePasswordFormSchema = z
  .object({
    currentPassword: z.string().min(1, PROFILE_TEXT.schema.current_password),

    newPassword: z.string().min(8, PROFILE_TEXT.schema.length),

    confirmPassword: z.string().min(1, PROFILE_TEXT.schema.comfirm_password),
  })
  .refine((data) => data.newPassword === data.confirmPassword, {
    path: ["confirmPassword"],
    message: PROFILE_TEXT.schema.not_confirm_password,
  });

export const changePasswordSchema = z.object({
  currentPassword: z.string().min(1, PROFILE_TEXT.schema.current_password),

  newPassword: z.string().min(8, PROFILE_TEXT.schema.length),
});

export type ChangePasswordFormValues = z.infer<typeof changePasswordFormSchema>;
