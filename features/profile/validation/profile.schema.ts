import { z } from "zod";

export const updateProfileSchema = z.object({
  first_name: z
    .string()
    .trim()
    .min(2, "Ім'я повинно містити щонайменше 2 символи.")
    .max(50, "Ім'я має містити менше ніж 50 символів."),

  last_name: z
    .string()
    .trim()
    .min(2, "Прізвище повинно містити щонайменше 2 символи.")
    .max(50, "Прізвище має містити менше ніж 50 символів."),
});

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;
