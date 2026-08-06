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
    success: "Профіль оновлено",
    succes_change: "Пароль змінено",
  },

  schema: {
    current_password: "Введіть поточний пароль",
    length: "Пароль повинен містити мінімум 8 символів",
    comfirm_password: "Підтвердіть пароль",
    not_confirm_password: "Паролі не співпадають",
    first_name_min: "Ім'я повинно містити щонайменше 2 символи.",
    last_name_min: "Прізвище повинно містити щонайменше 2 символи.",
    first_name_max: "Ім'я має містити менше ніж 50 символів.",
    last_name_max: "Прізвище має містити менше ніж 50 символів.",
  },

  error: {
    not_found: "Користувача не знайдено",
    wrong: "Поточний пароль неправильний",
    not_new: "Новий пароль повинен відрізнятися від поточного",
    in_top_five: "Не можна використовувати один із останніх 5 паролів",
  },

  saving: "Збереження...",
  changed: "Зберегти зміни",

  loading: "Завантаження...",
} as const;
