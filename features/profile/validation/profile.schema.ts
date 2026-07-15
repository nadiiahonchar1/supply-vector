import { z } from "zod";

export const updateProfileSchema = z.object({
  first_name: z
    .string()
    .trim()
    .min(2, "First name must contain at least 2 characters")
    .max(50, "First name must be shorter than 50 characters"),

  last_name: z
    .string()
    .trim()
    .min(2, "Last name must contain at least 2 characters")
    .max(50, "Last name must be shorter than 50 characters"),
});

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;
