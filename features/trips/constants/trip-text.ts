export const TRIP_TEXT = {
  error: {
    empty_trip: "Рейс не знайдено",

    vehicle_not_found: "Транспортний засіб не знайдено",

    vehicle_inactive: "Транспортний засіб неактивний",

    origin_store_not_found: "Склад-відправник не знайдено",

    invalid_time_window: "Некоректний період рейсу",

    invalid_status_transition: "Некоректна зміна статусу рейсу",

    forbidden_view: "Недостатньо прав для перегляду рейсів",

    forbidden_create: "Недостатньо прав для створення рейсу",

    forbidden_update: "Недостатньо прав для зміни рейсу",

    forbidden_cancel: "Недостатньо прав для скасування рейсу",

    cannot_update_delivered: "Завершений рейс не можна змінити",

    cannot_update_cancelled: "Скасований рейс не можна змінити",
  },

  success: {
    created: "Рейс успішно створено",
    updated: "Рейс успішно оновлено",
  },
} as const;
