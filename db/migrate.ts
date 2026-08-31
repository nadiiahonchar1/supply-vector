import { config } from "dotenv";
config({ path: ".env.local" });
config();

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(__dirname, "migrations");

type SqlClient = (typeof import("./index"))["sql"];

async function ensureMigrationsTable(sql: SqlClient) {
  await sql`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id TEXT PRIMARY KEY,
      applied_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
  `;
}

async function getAppliedMigrations(sql: SqlClient): Promise<Set<string>> {
  const rows = (await sql`
    SELECT id FROM schema_migrations
  `) as { id: string }[];

  return new Set(rows.map((row) => row.id));
}

function stripLineComments(fileContent: string): string {
  return fileContent
    .split("\n")
    .map((line) => {
      const commentIndex = line.indexOf("--");
      return commentIndex === -1 ? line : line.slice(0, commentIndex);
    })
    .join("\n");
}

function splitStatements(fileContent: string): string[] {
  return stripLineComments(fileContent)
    .split(";")
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

async function run() {
 
  const { sql } = await import("./index");

  await ensureMigrationsTable(sql);

  const applied = await getAppliedMigrations(sql);

  const files = readdirSync(MIGRATIONS_DIR)
    .filter((file) => file.endsWith(".sql"))
    .sort();

  const pending = files.filter((file) => !applied.has(file));

  if (pending.length === 0) {
    console.log("No pending migrations.");
    return;
  }

  for (const file of pending) {
    console.log(`Applying ${file}...`);

    const content = readFileSync(join(MIGRATIONS_DIR, file), "utf-8");
    const statements = splitStatements(content);

    for (const statement of statements) {
      await sql.query(statement);
    }

    await sql`
      INSERT INTO schema_migrations (id) VALUES (${file})
    `;

    console.log(`  ✓ ${file}`);
  }

  console.log(`Applied ${pending.length} migration(s).`);
}

run()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
