export const PRODUCT_TEXT = {
  error: {
    empty_product: "Товар не знайдено",
    duplicate_sku: "Товар з таким SKU вже існує",
    forbidden_create: "Недостатньо прав для створення товару",
    forbidden_update: "Недостатньо прав для редагування товару",
  },

  success: {
    created: "Товар успішно створено",
    updated: "Товар успішно оновлено",
  },
} as const;
