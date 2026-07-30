export const PROFILE_TEXT = {
  title: "Обліковий запис",

  table: {
    first_name: "Ім'я",
    last_name: "Прізвище",
    email: "Email",
    role: "Роль",
    status: "Статус",
    user_id: "Ідентифікатор користувача",
  },

  status: {
    active: "Активний",
    inactive: "Неактивний",
  },

  security_dialog: {
    current_password: "Діючий пароль",
    new_password: "Новий пароль",
    confirm_password: "Повторіть новий пароль",
    change: "Змінити пароль",
  },

  toast_masages: {
    success:"Профіль оновлено",
  },
  saving: "Збереження...",
  changed: "Зберегти зміни",

  loading: "Завантаження...",
} as const;
