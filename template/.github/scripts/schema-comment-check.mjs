#!/usr/bin/env node
/**
 * Diff-scoped Prisma schema-comment gate: columns and enums.
 *
 * Fails only when a PR ADDS or MODIFIES a model field (a real DB column) or an
 * enum declaration/member in a `*.prisma` schema without a `///` doc comment.
 * Pre-existing uncommented columns and enums are grandfathered — the author
 * only "owns" the lines the diff actually touches. Same diff-scoped philosophy
 * as the suppression and reuse gates in pr-gates.yml: enforce the new, don't
 * boil the ocean.
 *
 * Why `///` (triple slash) and not `//`: only `///` is a Prisma *documentation*
 * comment. It rides into the generated client as JSDoc and can be synced to a
 * Postgres `COMMENT ON COLUMN` (Prisma Migrate does not emit those itself), so
 * the description is readable straight from the column in `psql \d+`. A plain
 * `//` comment reaches neither.
 *
 * What counts as a column: a field inside a `model {}` block whose (base) type
 * is a Prisma scalar or an enum. Relation navigation fields (base type is
 * another model) are NOT columns and are skipped; the FK *scalar* they ride
 * next to (e.g. `organizationId String`) IS a column and is enforced. Block
 * attributes (`@@map`, `@@index`, ...) are skipped.
 *
 * A second, stricter rule applies to nullable columns (type ends in `?`,
 * including `Unsupported("...")?`): a doc comment alone is not enough — the
 * gathered doc text (the whole contiguous `///` block above the field, plus
 * any trailing `///` on the field line) must say what NULL *means* for that
 * column. A nullable column is really two states glued to one type, and the
 * schema itself cannot tell you which reading applies; the comment is the
 * only place that distinction can live, so it must actually make it. The
 * check is a crude `/\bnull/i` substring test on purpose — it forces the
 * author to answer the question, it does not grade the answer.
 *
 * ENUMS carry a third rule, and it has a different shape because Postgres has
 * a hard limitation here. An enum member is where domain semantics live —
 * `VoteDerivation.UNANIMOUS_RECOVERY` says something about how much to trust a
 * row that its identifier alone does not — so touched enum declarations and
 * members must each carry a `///`, exactly like columns. But the schema file
 * is not the only audience: anyone reading the database through psql, a BI
 * tool, or a schema browser sees none of it, because Prisma Migrate does not
 * emit `COMMENT ON` from `///`.
 *
 * For columns that is fixable per column. For enums it is not: **Postgres has
 * no per-label comment**. `COMMENT ON TYPE` exists; `COMMENT ON ENUM LABEL`
 * and `COMMENT ON VALUE` are both syntax errors (verified on PG 15). So the
 * only way member descriptions reach the database is folded into the one
 * type-level comment. That is why the parity rule below asks for a
 * `COMMENT ON TYPE "<Enum>"` in a migration rather than one comment per
 * member — it is not a loose approximation of the ideal rule, it IS the
 * strictest rule Postgres can express.
 *
 * The parity rule is diff-scoped like the rest: touch an enum block, and the
 * same PR must add a `COMMENT ON TYPE` for that enum in a migration under the
 * schema's `migrations/` directory. It is skipped entirely unless the
 * datasource provider is `postgresql` — `COMMENT ON TYPE` is not portable, and
 * a MySQL/SQLite repo syncing this gate must not be asked for DDL its engine
 * cannot parse.
 *
 * Fails CLOSED. A gate's failure mode is a green build: broken and working look
 * identical from the outside, so an unchecked column reads as a clean one. Every
 * assumption this parser makes about schema structure is therefore asserted, and
 * a violated assumption exits non-zero with CANNOT VERIFY rather than passing.
 * Preserve that property in any change here: when the parser is unsure, the only
 * safe answer is to refuse, never to skip the line and report success.
 *
 * Usage:
 *   node schema-comment-check.mjs [--base <ref>]
 *     --base   git ref to diff against. Defaults to origin/$GITHUB_BASE_REF,
 *              else "main".
 *
 * Zero dependencies. ESM. Reads HEAD-coordinate content via `git show`, so the
 * diff line numbers and the parsed schema always agree.
 */
import { execFileSync } from "node:child_process";

function git(args) {
  return execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function resolveBase() {
  const i = process.argv.indexOf("--base");
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (process.env.GITHUB_BASE_REF) return `origin/${process.env.GITHUB_BASE_REF}`;
  return "main";
}

/** Added/Modified *.prisma files in the PR diff. */
function changedSchemaFiles(base) {
  return git(["diff", "--name-only", "--diff-filter=AM", `${base}...HEAD`])
    .split("\n")
    .map((s) => s.trim())
    .filter((f) => f.endsWith(".prisma"));
}

/**
 * HEAD-coordinate line numbers added or modified in `file`, from a unified=0
 * diff. Each hunk header `@@ -a,b +c,d @@` names the added range c..c+d-1
 * directly; d===0 is a pure deletion (no added lines).
 */
function addedLineNumbers(base, file) {
  const diff = git(["diff", "--unified=0", `${base}...HEAD`, "--", file]);
  const added = new Set();
  for (const line of diff.split("\n")) {
    const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
    if (!m) continue;
    const start = parseInt(m[1], 10);
    const count = m[2] === undefined ? 1 : parseInt(m[2], 10);
    for (let i = 0; i < count; i += 1) added.add(start + i);
  }
  return added;
}

/** HEAD content of a file as an array of lines. */
function headLines(file) {
  return git(["show", `HEAD:${file}`]).split("\n");
}

/**
 * Is this schema backed by Postgres? Only Postgres has `COMMENT ON TYPE`, so
 * the enum parity rule is skipped everywhere else rather than demanding DDL
 * the target engine cannot parse. Read from the `datasource` block's
 * `provider`, which may be a literal or an `env("...")` indirection — the
 * latter is unknowable at gate time, so it is treated as NOT Postgres. That
 * direction is deliberate: a false skip costs a missing DB comment, a false
 * demand costs a build that cannot be made green.
 */
function usesPostgres(lines) {
  let inDatasource = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^datasource\s+\w+\s*\{/.test(trimmed)) { inDatasource = true; continue; }
    if (inDatasource && trimmed.startsWith("}")) { inDatasource = false; continue; }
    if (!inDatasource) continue;
    const m = trimmed.match(/^provider\s*=\s*"([^"]+)"/);
    if (m) return m[1] === "postgresql" || m[1] === "postgres";
  }
  return false;
}

/**
 * Postgres type name -> the comment TEXT it is given by a `COMMENT ON TYPE` on
 * a line the PR ADDED, in any `.sql` file under the schema's `migrations/`
 * directory.
 *
 * Added lines only, not the whole migration tree: a `COMMENT ON TYPE` written
 * months ago describes the enum as it was then, and would silently satisfy the
 * gate for a member added today. Requiring the statement in THIS diff is what
 * makes the comment track the member list.
 *
 * The text is returned, not just the name, because existence alone is a weak
 * rule — it passes a statement that never mentions the member being added. The
 * caller checks the added member names actually appear in it.
 *
 * The literal is matched as a single-quoted string with `''` escapes rather
 * than "up to the next semicolon": these comments are prose, and prose contains
 * semicolons.
 */
function addedEnumComments(base, schemaFile) {
  const migrationsDir = `${schemaFile.split("/").slice(0, -1).concat("migrations").join("/")}`;
  const diff = git(["diff", "--unified=0", `${base}...HEAD`, "--", `${migrationsDir}/*.sql`]);
  const addedSql = diff
    .split("\n")
    .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
    .map((line) => line.slice(1))
    .join("\n");

  const commented = new Map();
  const re = /COMMENT\s+ON\s+TYPE\s+(?:"?public"?\s*\.\s*)?"?(\w+)"?\s+IS\s+('(?:[^']|'')*')/gi;
  let m;
  while ((m = re.exec(addedSql)) !== null) commented.set(m[1], m[2]);
  return commented;
}

/** Names of every `model` and `enum` declared in the file (for relation detection). */
function collectTypeNames(lines) {
  const models = new Set();
  const enums = new Set();
  for (const line of lines) {
    let m = line.match(/^\s*model\s+(\w+)\s*\{/);
    if (m) models.add(m[1]);
    m = line.match(/^\s*enum\s+(\w+)\s*\{/);
    if (m) enums.add(m[1]);
  }
  return { models, enums };
}

/**
 * The full `///` doc text associated with the field at index `idx`: every
 * contiguous `///` line walking upward through the block, joined with the
 * trailing `///` on the field line itself (if any). Returns "" when the field
 * has no doc comment at all.
 */
function docText(lines, idx) {
  const parts = [];

  // Trailing `///` on the field line itself — ignore `//` sequences inside
  // quoted strings (e.g. a URL default) by blanking quoted spans first.
  const bare = lines[idx].replace(/"(?:[^"\\]|\\.)*"/g, "");
  const trailingIdx = bare.indexOf("///");
  if (trailingIdx !== -1) parts.push(lines[idx].slice(trailingIdx));

  // Leading `///` block directly above the field: walk upward while lines
  // are contiguous `///` comments (Prisma associates the whole contiguous
  // block with the field beneath it, not just the adjacent line).
  const leading = [];
  let i = idx - 1;
  while (i >= 0 && lines[i].trim().startsWith("///")) {
    leading.unshift(lines[i].trim());
    i -= 1;
  }
  parts.unshift(...leading);

  return parts.join("\n");
}

/** Does the field at index `idx` carry a `///` doc comment (leading or trailing)? */
function hasDocComment(lines, idx) {
  return docText(lines, idx) !== "";
}

function baseType(rawType) {
  return rawType.replace(/[\[\]?]/g, "");
}

/** Is the field's raw captured type token nullable (trailing `?`, incl. `Unsupported("...")?`)? */
function isNullableType(rawType) {
  return rawType.endsWith("?");
}

/**
 * Raised when the parser cannot confidently interpret the schema. The gate
 * treats this as a failure, never as a pass: an unparsed model is an unchecked
 * model, and silently passing one is the exact failure this gate exists to
 * prevent. See `main()` for the operator-facing message.
 */
class UnparseableSchemaError extends Error {
  constructor(file, line, detail) {
    super(`${file}:${line} — ${detail}`);
    this.name = "UnparseableSchemaError";
  }
}

/**
 * Walk the file, return the violations found on added/modified lines:
 *   - `missingDoc`: column fields with no `///` doc comment at all.
 *   - `missingNullSemantics`: nullable column fields that DO have a doc
 *     comment, but its text never says what NULL means.
 *   - `missingEnumDoc`: enum declarations and members with no `///`.
 * Plus `touchedEnums`, the Postgres type names whose block this PR changed —
 * `main()` pairs that against the migrations to enforce COMMENT ON parity.
 *
 * Fails closed. The checks below assert invariants that valid Prisma cannot
 * violate — a model always closes, brace depth never goes negative, and a
 * model only ends on a closing brace. When one of them breaks, the parser has
 * lost the plot and would skip real columns while reporting success, so it
 * throws instead of guessing.
 */
function findViolations(file, lines, addedLines, models) {
  const missingDoc = [];
  const missingNullSemantics = [];
  const missingEnumDoc = [];
  /** Postgres type name -> { name, line } for every enum this PR touched. */
  const touchedEnums = new Map();
  /** The block we're inside, or null at top level: { kind, name, openLine }. */
  let block = null;
  let depth = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    const trimmed = raw.trim();
    const lineNo = i + 1; // 1-indexed

    if (!block) {
      if (!trimmed || trimmed.startsWith("//")) continue;
      const open = trimmed.match(/^(model|enum|view|type|datasource|generator)\s+(\w+)\s*\{/);
      if (open) {
        block = { kind: open[1], name: open[2], openLine: lineNo, dbName: open[2], touched: false, addedMembers: [] };
        depth = 1;
        if (block.kind === "enum" && addedLines.has(lineNo)) {
          // A touched enum needs its own `COMMENT ON TYPE`, whether the change
          // was to the declaration or to a member below it.
          block.touched = true;
          if (docText(lines, i) === "") {
            missingEnumDoc.push({ file, line: lineNo, enumName: block.name, member: null });
          }
        }
        continue;
      }
      // Top level is only blanks, comments, and block openers. Anything else
      // means a block closed earlier than it should have (e.g. a stray `}`),
      // and fields below it are now invisible to the walk above.
      if (addedLines.has(lineNo)) {
        throw new UnparseableSchemaError(
          file,
          lineNo,
          "line sits outside any block — the parser has lost track of the schema's structure, " +
            "so columns below it would go unchecked",
        );
      }
      continue;
    }

    // Skip blanks and comments BEFORE the brace math below. Prose — including
    // the `///` docs this gate exists to encourage — may carry an unbalanced
    // `}` (e.g. describing a JSON envelope), which would otherwise close the
    // block early and silently stop checking every column beneath it.
    if (!trimmed || trimmed.startsWith("//")) continue;

    // Track brace depth so nested `{}` (block attribute args) don't end the
    // model early. Quoted spans are blanked first so a brace inside a string
    // default (`@default("{}")`) doesn't skew the count.
    const unquoted = raw.replace(/"(?:[^"\\]|\\.)*"/g, '""');
    depth += (unquoted.match(/\{/g) || []).length - (unquoted.match(/\}/g) || []).length;

    if (depth < 0) {
      throw new UnparseableSchemaError(file, lineNo, `unbalanced '}' inside ${block.kind} ${block.name}`);
    }
    if (depth === 0) {
      // Nothing but a closing brace ends a block. Depth hitting zero anywhere
      // else means the accounting drifted, and every column below this point
      // would go unchecked.
      if (!trimmed.startsWith("}")) {
        throw new UnparseableSchemaError(
          file,
          lineNo,
          `${block.kind} ${block.name} (opened line ${block.openLine}) appears to end on a line that is not a closing brace`,
        );
      }
      if (block.kind === "enum" && block.touched) {
        touchedEnums.set(block.dbName, { name: block.name, line: block.openLine, addedMembers: block.addedMembers });
      }
      block = null;
      continue;
    }

    if (block.kind === "enum") {
      // `@@map("x")` renames the Postgres type, so it is the name the
      // `COMMENT ON TYPE` must use — not the Prisma identifier.
      const mapped = trimmed.match(/^@@map\("([^"]+)"\)/);
      if (mapped) {
        block.dbName = mapped[1];
        if (addedLines.has(lineNo)) block.touched = true;
        continue;
      }
      if (trimmed.startsWith("@@")) continue;

      const member = trimmed.match(/^(\w+)\s*(?:@map\("[^"]*"\))?\s*$/);
      if (!member) {
        // Same fail-closed contract as model bodies: a touched line the parser
        // cannot classify might be an undocumented member, and "can't tell"
        // must not read as "fine".
        if (addedLines.has(lineNo)) {
          throw new UnparseableSchemaError(
            file,
            lineNo,
            `cannot classify this line inside enum ${block.name} — the gate cannot confirm it is not an undocumented member`,
          );
        }
        continue;
      }
      if (!addedLines.has(lineNo)) continue;
      block.touched = true;
      block.addedMembers.push(member[1]);
      if (docText(lines, i) === "") {
        missingEnumDoc.push({ file, line: lineNo, enumName: block.name, member: member[1] });
      }
      continue;
    }

    // Only model bodies hold columns. Datasource settings and generator
    // options are declarations of another kind entirely.
    if (block.kind !== "model") continue;

    // Skip block attributes (`@@map`, `@@index`, ...) — not columns.
    if (trimmed.startsWith("@@")) continue;

    const m = trimmed.match(/^(\w+)\s+(Unsupported\("[^"]*"\)\??|[\w\[\]?.]+)/);
    if (!m) {
      // An unrecognised line the PR actually touched. It may or may not be a
      // column; the gate can't tell, and "can't tell" must not read as "fine".
      // Untouched lines stay grandfathered, per the diff-scoped contract.
      if (addedLines.has(lineNo)) {
        throw new UnparseableSchemaError(
          file,
          lineNo,
          `cannot classify this line inside model ${block.name} — the gate cannot confirm it is not an undocumented column`,
        );
      }
      continue;
    }
    const [, fieldName, rawType] = m;

    // Relation navigation fields (base type is another model) are not columns.
    if (models.has(baseType(rawType))) continue;

    if (!addedLines.has(lineNo)) continue;

    const doc = docText(lines, i);
    if (doc === "") {
      missingDoc.push({ file, line: lineNo, field: fieldName });
      continue;
    }

    if (isNullableType(rawType) && !/\bnull/i.test(doc)) {
      missingNullSemantics.push({ file, line: lineNo, field: fieldName });
    }
  }

  if (block) {
    throw new UnparseableSchemaError(file, block.openLine, `${block.kind} ${block.name} is never closed`);
  }

  return { missingDoc, missingNullSemantics, missingEnumDoc, touchedEnums };
}

function main() {
  const base = resolveBase();
  const files = changedSchemaFiles(base);

  if (files.length === 0) {
    console.log("schema-comment-check: no *.prisma changes in diff — nothing to enforce.");
    return;
  }

  const missingDoc = [];
  const missingNullSemantics = [];
  const missingEnumDoc = [];
  const missingEnumComment = [];
  try {
    for (const file of files) {
      const lines = headLines(file);
      const { models } = collectTypeNames(lines);
      const added = addedLineNumbers(base, file);
      const violations = findViolations(file, lines, added, models);
      missingDoc.push(...violations.missingDoc);
      missingNullSemantics.push(...violations.missingNullSemantics);
      missingEnumDoc.push(...violations.missingEnumDoc);

      if (usesPostgres(lines) && violations.touchedEnums.size > 0) {
        const commented = addedEnumComments(base, file);
        for (const [dbName, where] of violations.touchedEnums) {
          const commentText = commented.get(dbName);
          if (commentText === undefined) {
            missingEnumComment.push({ file, line: where.line, enumName: where.name, dbName, uncovered: [] });
            continue;
          }
          // A statement that never names the member being added is not parity —
          // it is the previous comment re-applied. Restating the full member
          // list is the documented contract; this is what enforces it.
          const uncovered = where.addedMembers.filter((m) => !commentText.includes(m));
          if (uncovered.length > 0) {
            missingEnumComment.push({ file, line: where.line, enumName: where.name, dbName, uncovered });
          }
        }
      }
    }
  } catch (err) {
    if (!(err instanceof UnparseableSchemaError)) throw err;
    console.error(
      "schema-comment-check: CANNOT VERIFY — the gate could not parse the schema, so it is failing\n" +
        "closed rather than reporting a pass it did not earn.\n",
    );
    console.error(`  ${err.message}\n`);
    console.error(
      "This is a gate limitation or a schema construct the parser doesn't handle — not a missing\n" +
        "doc comment. Fix .github/scripts/schema-comment-check.mjs (and port the fix to the sibling\n" +
        "gates in reportal and the engineering-harness template). Do not work around it by\n" +
        "reshaping the schema to satisfy the parser.",
    );
    process.exit(1);
  }

  const failures = missingDoc.length + missingNullSemantics.length + missingEnumDoc.length + missingEnumComment.length;
  if (failures === 0) {
    console.log(
      `schema-comment-check: PASS — every new/changed column and enum member in ${files.join(", ")} ` +
        "has a /// doc comment, and every touched enum carries a COMMENT ON TYPE.",
    );
    return;
  }

  if (missingDoc.length > 0) {
    console.error("schema-comment-check: FAIL — new/modified columns without a /// doc comment:\n");
    for (const v of missingDoc) {
      console.error(`  ${v.file}:${v.line}  ${v.field}`);
    }
    console.error(
      "\nAdd a /// doc comment above each column (spell out acronyms and units). " +
        "Example:\n  /// Average revenue per paying member, in integer cents (MRR / payingMembers).\n  arpuCents Int @default(0)",
    );
  }

  if (missingNullSemantics.length > 0) {
    if (missingDoc.length > 0) console.error("");
    console.error(
      "schema-comment-check: FAIL — nullable columns whose doc comment never says what NULL means:\n",
    );
    for (const v of missingNullSemantics) {
      console.error(`  ${v.file}:${v.line}  ${v.field}`);
    }
    console.error(
      "\nA nullable column encodes a second state on top of its type, and the schema cannot\n" +
        "tell you which one. \"Not yet closed\", \"closed but the time is unknown\", \"closing is\n" +
        "not applicable to this row\" are three different columns with identical DDL. Say which\n" +
        "one this is in the /// comment — the word \"null\" must appear.",
    );
  }

  if (missingEnumDoc.length > 0) {
    console.error("\nschema-comment-check: FAIL — new/modified enum declarations or members without a /// doc comment:\n");
    for (const v of missingEnumDoc) {
      console.error(`  ${v.file}:${v.line}  ${v.enumName}${v.member ? `.${v.member}` : ""}`);
    }
    console.error(
      "\nAn enum member's name is a label, not a definition. Say what the value means for a row\n" +
        "that carries it — especially what it implies about how much to trust that row. Example:\n" +
        "  /// The outcome was recovered from a unanimous voice vote; no per-member roll call was\n" +
        "  /// heard, so individual positions are inferred rather than observed.\n" +
        "  UNANIMOUS_RECOVERY",
    );
  }

  if (missingEnumComment.length > 0) {
    console.error("\nschema-comment-check: FAIL — enums changed without a matching COMMENT ON TYPE in a migration:\n");
    for (const v of missingEnumComment) {
      const why = v.uncovered.length === 0
        ? `no COMMENT ON TYPE "${v.dbName}" in this PR's migrations`
        : `COMMENT ON TYPE "${v.dbName}" never mentions: ${v.uncovered.join(", ")}`;
      console.error(`  ${v.file}:${v.line}  ${v.enumName}  — ${why}`);
    }
    console.error(
      "\nPrisma Migrate does not emit COMMENT ON from /// doc comments, so without this the\n" +
        "description exists only in the schema file and is invisible in psql, BI tools, and every\n" +
        "other schema browser. Add a hand-written statement to this PR's migration.\n\n" +
        "Postgres has NO per-label comment (COMMENT ON ENUM LABEL and COMMENT ON VALUE are both\n" +
        "syntax errors), so fold the member descriptions into the one type-level comment:\n\n" +
        '  COMMENT ON TYPE "VoteValue" IS\n' +
        "    'How a legislator voted on a matter.\n" +
        "     YEA: voted in favour. NAY: voted against. ABSTAIN: present and declined to vote.\n" +
        "     RECUSED: withdrew for a declared conflict — distinct from ABSTAIN.';\n\n" +
        "Restate the full member list each time the enum changes; the statement replaces the\n" +
        "previous comment wholesale rather than appending to it.",
    );
  }

  process.exit(1);
}

main();
