Migrations

Numbered, forward-only SQL migrations. No down-migrations — if a migration needs undoing, write a new migration that reverts it.

Running
bash
npm run db:migrate

Applies every NNNN\_\*.sql file in this folder that isn't yet recorded in the schema_migrations table (created automatically on first run), in filename order.

Adding a migration
Create the next numbered file, e.g. 0003_something.sql (4-digit prefix, zero-padded, incrementing by one).
Write plain SQL — CREATE TABLE, ALTER TABLE, etc.
Run npm run db:migrate locally against your dev DB to verify it applies cleanly before pushing.
Constraints to keep in mind
No semicolons inside string literals or function bodies. The runner strips -- line comments and then splits each file into statements on ; — it does not parse SQL, so a semicolon inside a string literal (not inside a -- comment — those are handled) will still break it. Stick to plain DDL (CREATE TABLE, ALTER TABLE, CREATE VIEW); avoid DO $$ ... $$ blocks or PL/pgSQL functions in a migration file.
Not atomic across statements. The Neon HTTP driver (@neondatabase/serverless, used everywhere else in this project) has no interactive transactions, so each statement in a migration runs on its own — if statement 3 of 5 fails, statements 1-2 are already committed and won't be rolled back. Write every statement so it's safe to re-run (IF NOT EXISTS, ADD COLUMN guarded appropriately, idempotent UPDATE ... WHERE) so that fixing the failing statement and re-running db:migrate just picks up where it left off, instead of erroring on the already-applied part. 0001_init.sql is the one exception that needs IF NOT EXISTS everywhere for a different reason (it mirrors schema already live in production) — migrations after it don't need that, since schema_migrations already guarantees each file only runs once per database.
Migration files are never edited after being merged. If something's wrong with an applied migration, write a new one that fixes it forward.
