export const LOGISTICS_DECISION_ENGINE_TEXT = {
  error: {
    request_not_approved:
      "Для логістичної рекомендації заявка має бути погоджена",
    no_available_shipments:
      "Немає відправлень із доступною для призначення кількістю товару",
    no_existing_trips: "Не знайдено відповідних поїздок",
    request_not_found: "Заявку на переміщення не знайдено",
    no_available_vehicles:
      "Не знайдено транспортних засобів із достатньою місткістю",
    insufficient_capacity: "Недостатньо вільної місткості транспорту",
    forbidden_view: "Недостатньо прав для перегляду логістичних рекомендацій",
    forbidden_update: "Недостатньо прав для зміни логістичних рекомендацій",
    forbidden_create:
      "Недостатньо прав для створення логістичного рекомендацій",
  },
} as const;
