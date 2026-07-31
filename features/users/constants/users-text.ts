export const USERS_TEXT = {
  title: "Користувачі",
  subtitle: "Керуйте користувачами системи та їхніми ролями.",

  create: "Створити користувача",
  creating: "Створення користувача",

  table: {
    firstName: "Ім'я",
    lastName: "Прізвище",
    email: "Email",
    role: "Роль",
    status: "Статус",
    actions: "Дії",
  },

  status: {
    active: "Активний",
    inactive: "Неактивний",
  },

  role: {
    superadmin: "Суперадміністратор",
    admin: "Адміністратор",
    manager: "Менеджер",
    operator: "Оператор",
  },

  actions: {
    changeRole: "Змінити роль",
    assignStores: "Призначити магазини",
    activate: "Активувати",
    deactivate: "Деактивувати",
    resetPassword: "Скинути пароль",
    comingSoon: "Скоро",
  },

  success_dialog: {
    success: "Користувача успішно створено",
    temporary_password: "Тимчасовий пароль:",
    message:
      "Збережіть цей пароль. Після закриття цього вікна він більше не буде доступний.",
    copy: "Скопіювати",
    close: "Закрити",
  },

  loading: "Завантаження користувачів...",
  empty: "Користувачів не знайдено.",
  error: "Не вдалося завантажити користувачів.",
} as const;
