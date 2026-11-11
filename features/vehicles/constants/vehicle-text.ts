export const VEHICLE_TEXT = {
  error: {
    empty_vehicle: "Машину не знайдено",
    forbidden_create: "Недостатньо прав для створення машини",
    forbidden_update: "Недостатньо прав для редагування машини",
    forbidden_view: "Недостатньо прав для перегляду машини",
    invalid_availability: "Некоректний період доступності машини",
    vehicle_has_active_trip: "Неможливо деактивувати транспортний засіб, поки він закріплений за активним рейсом",
  },

  success: {
    created: "Машину успішно створено",
    updated: "Машину успішно оновлено",
  },
} as const;
