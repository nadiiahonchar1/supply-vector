import { z } from "zod";
import { PROFILE_TEXT } from "../constants/profile-text";

export const updateProfileSchema = z.object({
  first_name: z
    .string()
    .trim()
    .min(2, PROFILE_TEXT.schema.first_name_min)
    .max(50, PROFILE_TEXT.schema.first_name_max),

  last_name: z
    .string()
    .trim()
    .min(2, PROFILE_TEXT.schema.last_name_min)
    .max(50, PROFILE_TEXT.schema.last_name_max),
});

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;
