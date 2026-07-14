import { z } from "zod";

export const profileSchema = z.object({
  first_name: z.string().trim().min(2, "First name is required").max(100),

  last_name: z.string().trim().min(2, "Last name is required").max(100),
});

export type ProfileFormValues = z.infer<typeof profileSchema>;
