export const LOGISTICS_DECISION_TEXT = {
  error: {
    empty_decision: "Логістичне рішення не знайдено",

    transfer_request_not_found: "Запит на переміщення не знайдено",

    transfer_request_not_available:
      "Запит на переміщення недоступний для логістичного рішення",

    trip_not_found: "Рейс не знайдено",

    trip_not_available: "Рейс недоступний для логістичного рішення",

    trip_required: "Для цього типу логістичного рішення потрібен рейс",

    trip_not_allowed:
      "Для цього типу логістичного рішення рейс не повинен бути вказаний",

    invalid_cost: "Некоректна вартість логістичного рішення",

    invalid_reasoning: "Необхідно вказати обґрунтування рішення",

    forbidden_view: "Недостатньо прав для перегляду логістичних рішень",

    forbidden_create: "Недостатньо прав для створення логістичного рішення",
  },

  success: {
    created: "Логістичне рішення успішно створено",
  },
} as const;
