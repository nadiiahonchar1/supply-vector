import { randomInt } from "crypto";

const LOWERCASE = "abcdefghijklmnopqrstuvwxyz";
const UPPERCASE = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const NUMBERS = "0123456789";
const SYMBOLS = "!@#$%&*";

const CHARSET = LOWERCASE + UPPERCASE + NUMBERS + SYMBOLS;

export function generateTemporaryPassword(length = 12): string {
  let password = "";

  for (let i = 0; i < length; i++) {
    password += CHARSET[randomInt(0, CHARSET.length)];
  }

  return password;
}
