#!/usr/bin/env node
/**
 * Diff-scoped Prisma column-comment gate.
 *
 * Fails only when a PR ADDS or MODIFIES a model field (a real DB column) in a
 * `*.prisma` schema without a `///` doc comment. Pre-existing uncommented
 * columns are grandfathered — the author only "owns" the lines the diff
 * actually touches. This mirrors the philosophy of diff-scoped-lint.js and
 * diff_scoped_complexity.py: enforce the new, don't boil the ocean.
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
 * Usage:
 *   node schema-comment-check.mjs [--base <ref>]
 *     --base   git ref to diff against. Defaults to origin/$GITHUB_BASE_REF,
 *              else "main".
 *
 * Zero dependencies. ESM. Reads HEAD-coordinate content via `git show`, so the
 * diff line numbers and the parsed schema always agree.
 */
import { execFileSync } from "node:child_process";

const PRISMA_SCALARS = new Set([
  "String", "Boolean", "Int", "BigInt", "Float", "Decimal", "DateTime", "Json", "Bytes",
]);

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
 * Walk the file, return violations: column fields on added lines lacking a
 * `///` doc comment. Each is { file, line, field }.
 */
function findViolations(file, lines, addedLines, models) {
  const violations = [];
  let inModel = false;
  let depth = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    const trimmed = raw.trim();

    if (!inModel) {
      if (/^\s*model\s+\w+\s*\{/.test(raw)) {
        inModel = true;
        depth = 1;
      }
      continue;
    }

    // Track brace depth so nested `{}` (block attribute args) don't end the model early.
    depth += (raw.match(/\{/g) || []).length - (raw.match(/\}/g) || []).length;
    if (depth <= 0) {
      inModel = false;
      continue;
    }

    // Skip blanks, comments, and block attributes (`@@...`).
    if (!trimmed || trimmed.startsWith("//") || trimmed.startsWith("@@")) continue;

    const m = trimmed.match(/^(\w+)\s+([\w\[\]?.]+)/);
    if (!m) continue;
    const [, fieldName, rawType] = m;

    // Relation navigation fields (base type is another model) are not columns.
    if (models.has(baseType(rawType))) continue;

    const lineNo = i + 1; // 1-indexed
    if (!addedLines.has(lineNo)) continue;
    if (hasDocComment(lines, i)) continue;

    violations.push({ file, line: lineNo, field: fieldName });
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
  for (const file of files) {
    const lines = headLines(file);
    const { models } = collectTypeNames(lines);
    const added = addedLineNumbers(base, file);
    all.push(...findViolations(file, lines, added, models));
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
