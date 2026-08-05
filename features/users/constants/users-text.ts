import { forbidden } from "next/navigation";

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
    action_activate: "Ви дійсно бажаєте активувати цього користувача?",
    action_deactivate: "Ви дійсно бажаєте деактивувати цього користувача?",
  },

  success_dialog: {
    success: "Користувача успішно створено",
    temporary_password: "Тимчасовий пароль:",
    message:
      "Збережіть цей пароль. Після закриття цього вікна він більше не буде доступний.",
    copy: "Скопіювати",
    close: "Закрити",
    success_role: "Роль користувача успішно змінена",
    success_activate: "Користувача успішно активовано",
    success_deactivate: "Користувача успішно деактивовано",
  },

  error: {
    loading: "Не вдалося завантажити користувачів.",
    empty_role: "Роль не знайдена",
    empty_user: "Користувачів не знайдено.",
    forbidded_permission_create:
      "Недостатньо прав для створення користувача з цією роллю",
    forbidden_permission_change: "Недостатньо прав для зміни статусу цього користувача",
    email: "Користувач з таким email вже існує",
  },

  loading: "Завантаження користувачів...",
} as const;
