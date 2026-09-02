export const STORES_TEXT = {
  error: {
    empty_store: "Магазин не знайдено",
    duplicate: "Магазин з такими даними вже існує",
    forbidden_create: "Недостатньо прав для створення магазину",
    forbidden_update: "Недостатньо прав для редагування магазину",
    invalid_coordinates: "Некоректні координати",
    invalid_capacity: "Некоректна максимальна місткість",
  },

  success: {
    created: "Магазин успішно створено",
    updated: "Магазин успішно оновлено",
  },
} as const;
