export const INVENTORY_TEXT = {
  error: {
    empty_inventory: "Запис залишків не знайдено",

    store_not_found: "Склад не знайдено",
    store_inactive: "Склад неактивний",
    store_not_storage_node:
      "Цей склад не може використовуватися як вузол зберігання",

    product_not_found: "Товар не знайдено",
    product_inactive: "Товар неактивний",

    inventory_already_exists:
      "Залишки для цього товару на цьому складі вже існують",

    invalid_min_stock: "Некоректний мінімальний запас",

    invalid_max_stock: "Некоректний максимальний запас",

    max_stock_less_than_min_stock:
      "Максимальний запас не може бути меншим за мінімальний запас",

    insufficient_quantity: "Недостатньо товару на складі",

    invalid_quantity_change: "Некоректна зміна кількості товару",

    forbidden_view: "Недостатньо прав для перегляду залишків",

    forbidden_create: "Недостатньо прав для створення запису залишків",

    forbidden_update: "Недостатньо прав для зміни налаштувань залишків",

    forbidden_adjust: "Недостатньо прав для коригування залишків",
  },

  success: {
    created: "Запис залишків успішно створено",
    updated: "Налаштування залишків успішно оновлено",
    adjusted: "Залишки успішно оновлено",
  },
} as const;
