import { z } from "zod";

import { ValidationError } from "@/lib/errors/errors";

export function validate<T>(schema: z.ZodSchema<T>, data: unknown): T {
  const result = schema.safeParse(data);

  if (!result.success) {
    throw new ValidationError(
      result.error.issues[0]?.message ?? "Помилка валідації",
    );
  }

  return result.data;
}
