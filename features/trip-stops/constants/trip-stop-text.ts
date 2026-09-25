export const TRIP_STOP_TEXT = {
  error: {
    empty_trip_stop: "Зупинку рейсу не знайдено",
    trip_not_found: "Рейс не знайдено",
    store_not_found: "Склад не знайдено",
    store_inactive: "Склад неактивний",

    invalid_sequence: "Некоректний порядок зупинки",

    sequence_already_exists: "Зупинка з таким порядковим номером вже існує",

    trip_not_modifiable: "Цей рейс більше не можна змінювати",

    forbidden_view: "Недостатньо прав для перегляду зупинок рейсу",

    forbidden_create: "Недостатньо прав для створення зупинки рейсу",

    forbidden_update: "Недостатньо прав для зміни зупинки рейсу",

    forbidden_delete: "Недостатньо прав для видалення зупинки рейсу",

    cannot_delete_origin: "Не можна видалити початкову зупинку рейсу",
  },

  success: {
    created: "Зупинку рейсу успішно створено",
    updated: "Зупинку рейсу успішно оновлено",
    deleted: "Зупинку рейсу успішно видалено",
  },
} as const;
