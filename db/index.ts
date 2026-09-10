import { neon } from "@neondatabase/serverless";

const databaseUrl = process.env.DATABASE_URL;

if (!databaseUrl) {
  throw new Error("DATABASE_URL is not defined");
}

export const sql = neon(databaseUrl, {
  types: {
    getTypeParser: (oid) => {
      if (oid === 1700) {
        return Number;
      }

      return undefined;
    },
  },
});
