export const SHIPMENT_TEXT = {
  error: {
    empty_shipment: "Відправлення не знайдено",
    invalid_transfer_request: "Некоректний запит на переміщення",
    transfer_request_not_found: "Запит на переміщення не знайдено",
    shipment_already_exists:
      "Для цього запиту на переміщення вже створено відправлення",
    invalid_status_transition: "Некоректна зміна статусу відправлення",
    forbidden_create: "Недостатньо прав для створення відправлення",
    forbidden_update: "Недостатньо прав для зміни відправлення",
  },
  success: {
    created: "Відправлення успішно створено",
    updated: "Відправлення успішно оновлено",
  },
} as const;
