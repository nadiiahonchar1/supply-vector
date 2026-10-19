# Migrations

Numbered, forward-only SQL migrations. No down-migrations — if a migration
needs undoing, write a new migration that reverts it.

## Running

```bash
npm run db:migrate
```

Applies every `NNNN_*.sql` file in this folder that isn't yet recorded in the
`schema_migrations` table (created automatically on first run), in filename
order. When nothing is pending it prints `No pending migrations.`

`DATABASE_URL` is read from `.env.local` (or `.env`) — check which database it
points to before running.

## Adding a migration

1. Create the next numbered file, e.g. `0014_something.sql` (4-digit prefix,
   zero-padded, incrementing by one).
2. Write plain SQL — `CREATE TABLE`, `ALTER TABLE`, `CREATE FUNCTION`, etc.
3. Run `npm run db:migrate` locally against your dev DB to verify it applies
   cleanly before pushing.

## Constraints to keep in mind

- **What the runner understands.** It splits each file into statements with
  `db/split-statements.ts`, a small state machine that knows `--` and
  `/* */` comments, `'string literals'` (including `''` escapes) and
  dollar-quoted blocks (`$$ ... $$` or `$tag$ ... $tag$`). A `;` inside any of
  those does **not** end a statement, so `DO $$` blocks and PL/pgSQL functions
  (`CREATE OR REPLACE FUNCTION ... AS $$ ... $$`) are fine. It is not a full SQL
  parser: `E'...'` strings with backslash-escaped quotes, and quoted identifiers
  containing `;` or `--`, are not handled.
- **Not atomic across statements.** The Neon HTTP driver
  (`@neondatabase/serverless`, used everywhere else in this project) has no
  interactive transactions, so each statement in a migration runs on its own —
  if statement 3 of 5 fails, statements 1-2 are already committed and won't be
  rolled back. Write every statement so it's safe to re-run (`IF NOT EXISTS`,
  idempotent `UPDATE ... WHERE`) so that fixing the failing statement and
  re-running `db:migrate` just picks up where it left off. `0001_init.sql` is
  the one exception that needs `IF NOT EXISTS` everywhere for a different
  reason (it mirrors schema already live in production). **Exception:** a `DO`
  block or a function body is ONE statement, so everything inside it is atomic
  (all-or-nothing) — that is how `0011`–`0013` get real transactional
  behaviour. Prefer one when several changes must succeed or fail together.
- **Never edit or rename a file after it has been applied.** The file _name_ is
  what `schema_migrations` stores, so a renamed file looks like a brand-new
  migration and the runner will try to apply it again. If something is wrong
  with an applied migration, write a new one that fixes it forward.
  (`0007 store coordinates.sql` and `0008 logistics decision source.sql`
  contain spaces for historical reasons — leave them as they are.)

## If you applied a migration by hand (Neon SQL Editor)

The runner only knows about files recorded in `schema_migrations`. If you ran a
migration manually and did not record it, the next `npm run db:migrate` will try
to apply it again and fail (for example `relation "..." already exists`).

1. Confirm the migration's effect really exists (a column in
   `information_schema.columns`, a constraint in `pg_constraint`, a function in
   `pg_proc`, an index in `pg_indexes`).
2. Record it, using the exact file name:

   ```sql
   INSERT INTO schema_migrations (id)
   VALUES ('0014_something.sql')
   ON CONFLICT DO NOTHING;
   ```

3. Run `npm run db:migrate` — it should print `No pending migrations.`

Prefer running migrations through `npm run db:migrate` so this bookkeeping
happens automatically.
