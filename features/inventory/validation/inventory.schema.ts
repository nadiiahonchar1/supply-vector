import { z } from "zod";

export const createInventorySchema = z.object({
  store_id: z.string().uuid(),
  product_id: z.string().uuid(),

  min_stock: z.number().int().nonnegative().optional(),
  max_stock: z.number().int().nonnegative().nullable().optional(),
});

export const updateInventorySchema = z
  .object({
    min_stock: z.number().int().nonnegative().optional(),
    max_stock: z.number().int().nonnegative().nullable().optional(),
  })
  .refine(
    (data) => data.min_stock !== undefined || data.max_stock !== undefined,
    {
      message: "Потрібно вказати хоча б одне поле для оновлення",
    },
  );

export const adjustInventorySchema = z.object({
  quantity_change: z
    .number()
    .int()
    .refine((value) => value !== 0, {
      message: "Зміна кількості не може дорівнювати нулю",
    }),

  movement_type: z.enum(["purchase", "sale", "adjustment", "return"]),
});
