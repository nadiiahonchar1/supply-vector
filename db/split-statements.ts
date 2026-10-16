// Splits a migration file into individual SQL statements.
//
// The Neon HTTP driver runs ONE statement per call, so the runner has
// to cut each file into statements itself. Cutting on every ";" is not
// enough any more: a PL/pgSQL function or a DO block has semicolons
// INSIDE its body, and those must not end the statement.
//
// This is a small state machine, not a full SQL parser. It knows about:
//
//   -- line comments      dropped (a ";" inside a comment is harmless)
//   /* block comments */  dropped
//   'string literals'     kept as-is; '' is an escaped quote
//   $$ ... $$             dollar-quoted body, kept as-is, ";" inside is
//   $tag$ ... $tag$       NOT a statement terminator
//
// Everything else is copied through, and a ";" outside all of the above
// ends the current statement.
//
// Not handled (not needed for this project's migrations): E'...'
// escape strings with backslash-quotes, and quoted identifiers
// containing ";" or "--" (e.g. "my;table").

const DOLLAR_TAG = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/;

export function splitStatements(sqlText: string): string[] {
  const statements: string[] = [];

  let current = "";
  let i = 0;

  // The opening tag (e.g. "$$" or "$body$") while we are inside a
  // dollar-quoted block, otherwise null.
  let dollarTag: string | null = null;
  let inSingleQuote = false;

  function endStatement() {
    const trimmed = current.trim();

    if (trimmed.length > 0) {
      statements.push(trimmed);
    }

    current = "";
  }

  while (i < sqlText.length) {
    const char = sqlText[i];
    const next = sqlText[i + 1];

    // Inside $$ ... $$ — copy everything until the matching closing tag.
    if (dollarTag !== null) {
      if (sqlText.startsWith(dollarTag, i)) {
        current += dollarTag;
        i += dollarTag.length;
        dollarTag = null;
      } else {
        current += char;
        i += 1;
      }

      continue;
    }

    // Inside '...' — copy until the closing quote ('' is an escaped quote).
    if (inSingleQuote) {
      current += char;

      if (char === "'") {
        if (next === "'") {
          current += next;
          i += 2;
          continue;
        }

        inSingleQuote = false;
      }

      i += 1;
      continue;
    }

    // -- line comment: skip to the end of the line.
    if (char === "-" && next === "-") {
      while (i < sqlText.length && sqlText[i] !== "\n") {
        i += 1;
      }

      continue;
    }

    // /* block comment */: skip to the closing marker.
    if (char === "/" && next === "*") {
      const end = sqlText.indexOf("*/", i + 2);

      i = end === -1 ? sqlText.length : end + 2;
      continue;
    }

    if (char === "'") {
      inSingleQuote = true;
      current += char;
      i += 1;
      continue;
    }

    if (char === "$") {
      const match = DOLLAR_TAG.exec(sqlText.slice(i));

      if (match) {
        dollarTag = match[0];
        current += dollarTag;
        i += dollarTag.length;
        continue;
      }
    }

    if (char === ";") {
      endStatement();
      i += 1;
      continue;
    }

    current += char;
    i += 1;
  }

  // A file whose last statement has no trailing ";".
  endStatement();

  return statements;
}
