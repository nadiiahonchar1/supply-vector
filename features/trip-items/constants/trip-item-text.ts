export const TRIP_ITEM_TEXT = {
  error: {
    empty_trip_item: "Елемент рейсу не знайдено",
    trip_not_found: "Рейс не знайдено",
    transfer_request_not_found: "Запит на переміщення не знайдено",
    transfer_request_not_available:
      "Запит на переміщення недоступний для додавання до рейсу",
    invalid_quantity: "Некоректна кількість товару",
    quantity_exceeds_request:
      "Кількість перевищує кількість у запиті на переміщення",
    quantity_exceeds_remaining:
      "Кількість перевищує залишок товару для цього запиту",
    dropoff_store_mismatch:
      "Точка розвантаження не відповідає складу призначення",
    pickup_store_mismatch:
      "Точка завантаження не відповідає складу-відправнику",
    invalid_stop_order:
      "Точка завантаження має бути раніше точки розвантаження",
    trip_not_modifiable: "Цей рейс більше не можна змінювати",
    forbidden_view: "Недостатньо прав для перегляду елементів рейсу",
    forbidden_create: "Недостатньо прав для додавання елемента до рейсу",
    forbidden_update: "Недостатньо прав для зміни елемента рейсу",
    forbidden_delete: "Недостатньо прав для видалення елемента рейсу",
  },
  success: {
    created: "Елемент рейсу успішно створено",
    updated: "Елемент рейсу успішно оновлено",
    deleted: "Елемент рейсу успішно видалено",
  },
} as const;
