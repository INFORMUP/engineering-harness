#!/usr/bin/env node
/**
 * Diff-scoped Prisma column-comment gate.
 *
 * Fails only when a PR ADDS or MODIFIES a model field (a real DB column) in a
 * `*.prisma` schema without a `///` doc comment. Pre-existing uncommented
 * columns are grandfathered — the author only "owns" the lines the diff
 * actually touches. Same diff-scoped philosophy as the suppression and reuse
 * gates in pr-gates.yml: enforce the new, don't boil the ocean.
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

/** Does the field at index `idx` carry a `///` doc comment (leading or trailing)? */
function hasDocComment(lines, idx) {
  // Trailing `///` on the field line itself — ignore `//` sequences inside
  // quoted strings (e.g. a URL default) by blanking quoted spans first.
  const bare = lines[idx].replace(/"(?:[^"\\]|\\.)*"/g, "");
  if (bare.includes("///")) return true;
  // Leading `///` on the immediately preceding line (Prisma associates a
  // contiguous `///` block directly above the field).
  const above = (lines[idx - 1] || "").trim();
  return above.startsWith("///");
}

function baseType(rawType) {
  return rawType.replace(/[\[\]?]/g, "");
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
 * Walk the file, return violations: column fields on added lines lacking a
 * `///` doc comment. Each is { file, line, field }.
 *
 * Fails closed. The checks below assert invariants that valid Prisma cannot
 * violate — a model always closes, brace depth never goes negative, and a
 * model only ends on a closing brace. When one of them breaks, the parser has
 * lost the plot and would skip real columns while reporting success, so it
 * throws instead of guessing.
 */
function findViolations(file, lines, addedLines, models) {
  const violations = [];
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
        block = { kind: open[1], name: open[2], openLine: lineNo };
        depth = 1;
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
      block = null;
      continue;
    }

    // Only model bodies hold columns. Enum members, datasource settings, and
    // generator options are declarations of another kind entirely.
    if (block.kind !== "model") continue;

    // Skip block attributes (`@@map`, `@@index`, ...) — not columns.
    if (trimmed.startsWith("@@")) continue;

    const m = trimmed.match(/^(\w+)\s+([\w\[\]?.]+)/);
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
    if (hasDocComment(lines, i)) continue;

    violations.push({ file, line: lineNo, field: fieldName });
  }

  if (block) {
    throw new UnparseableSchemaError(file, block.openLine, `${block.kind} ${block.name} is never closed`);
  }

  return violations;
}

function main() {
  const base = resolveBase();
  const files = changedSchemaFiles(base);

  if (files.length === 0) {
    console.log("schema-comment-check: no *.prisma changes in diff — nothing to enforce.");
    return;
  }

  const all = [];
  try {
    for (const file of files) {
      const lines = headLines(file);
      const { models } = collectTypeNames(lines);
      const added = addedLineNumbers(base, file);
      all.push(...findViolations(file, lines, added, models));
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

  if (all.length === 0) {
    console.log(`schema-comment-check: PASS — every new/changed column in ${files.join(", ")} has a /// doc comment.`);
    return;
  }

  console.error("schema-comment-check: FAIL — new/modified columns without a /// doc comment:\n");
  for (const v of all) {
    console.error(`  ${v.file}:${v.line}  ${v.field}`);
  }
  console.error(
    "\nAdd a /// doc comment above each column (spell out acronyms and units). " +
      "Example:\n  /// Average revenue per paying member, in integer cents (MRR / payingMembers).\n  arpuCents Int @default(0)",
  );
  process.exit(1);
}

main();
