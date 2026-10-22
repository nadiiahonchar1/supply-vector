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

export const adjustInventorySchema = z
  .object({
    quantity_change: z
      .number()
      .int()
      .refine((value) => value !== 0, {
        message: "Зміна кількості не може дорівнювати нулю",
      }),

    movement_type: z.enum(["purchase", "sale", "adjustment", "return"]),
  })
  .superRefine((data, ctx) => {
    const { quantity_change, movement_type } = data;

    const invalidDirection =
      (movement_type === "purchase" && quantity_change < 0) ||
      (movement_type === "return" && quantity_change < 0) ||
      (movement_type === "sale" && quantity_change > 0);

    if (invalidDirection) {
      ctx.addIssue({
        code: "custom",
        path: ["quantity_change"],
        message: "Напрямок зміни кількості не відповідає типу руху товару",
      });
    }
  });

export const inventoryFiltersSchema = z.object({
  store_id: z.string().uuid().optional(),
  product_id: z.string().uuid().optional(),
  city: z.string().trim().min(1).optional(),
  low_stock: z.enum(["true", "false"]).optional(),
});

export const inventoryMovementFiltersSchema = z.object({
  store_id: z.string().uuid().optional(),
  product_id: z.string().uuid().optional(),
  movement_type: z
    .enum([
      "purchase",
      "sale",
      "transfer_in",
      "transfer_out",
      "adjustment",
      "return",
    ])
    .optional(),
});