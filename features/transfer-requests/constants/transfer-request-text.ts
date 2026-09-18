export const TRANSFER_REQUEST_TEXT = {
  error: {
    empty_transfer_request: "Запит на переміщення не знайдено",

    source_store_not_found: "Склад-відправник не знайдено",

    destination_store_not_found: "Склад-отримувач не знайдено",

    product_not_found: "Товар не знайдено",

    same_stores: "Склад-відправник та склад-отримувач повинні відрізнятися",

    invalid_delivery_window: "Некоректний період доставки",

    invalid_quantity: "Кількість товару повинна бути більше нуля",

    invalid_status_transition: "Некоректна зміна статусу запиту на переміщення",

    shipment_already_exists:
      "Для цього запиту на переміщення вже створено відправлення",

    cannot_update_fulfilled: "Виконаний запит на переміщення не можна змінити",

    cannot_update_cancelled: "Скасований запит на переміщення не можна змінити",

    forbidden_create: "Недостатньо прав для створення запиту на переміщення",

    forbidden_update: "Недостатньо прав для зміни запиту на переміщення",

    forbidden_cancel: "Недостатньо прав для скасування запиту на переміщення",

    forbidden_view: "Недостатньо прав для перегляду запитів на переміщення",
  },

  success: {
    created: "Запит на переміщення успішно створено",
    updated: "Запит на переміщення успішно оновлено",
  },
} as const;
