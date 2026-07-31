// Self-test for template/.github/scripts/schema-comment-check.mjs
//
// Zero npm deps: node:test + node:assert/strict + node:child_process/fs/os/path.
// Each test builds its own hermetic temp git repo (base commit + a "feature"
// commit on top) so nothing depends on this harness repo's own history.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(__dirname, "..", "template", ".github", "scripts", "schema-comment-check.mjs");

function git(cwd, args) {
  return execFileSync("git", args, { cwd, encoding: "utf8" });
}

/**
 * Build a temp git repo with `base.schema.prisma` committed, then a "feature"
 * commit that overwrites schema.prisma with `headSchema` (and, when
 * `extraHeadFiles` is given, also writes those non-schema files in the head
 * commit — used for the "no prisma change" case). Runs the gate against the
 * base commit and returns { code, output } where output is combined
 * stdout+stderr.
 */
function runGate(baseSchema, headSchema, extraHeadFiles = {}, extraBaseFiles = {}) {
  const write = (tmp, name, contents) => {
    const full = path.join(tmp, name);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, contents);
  };

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "schema-gate-"));
  try {
    git(tmp, ["init", "-q"]);
    git(tmp, ["config", "user.email", "test@example.com"]);
    git(tmp, ["config", "user.name", "Test"]);
    git(tmp, ["config", "commit.gpgsign", "false"]);

    fs.writeFileSync(path.join(tmp, "schema.prisma"), baseSchema);
    for (const [name, contents] of Object.entries(extraBaseFiles)) write(tmp, name, contents);
    git(tmp, ["add", "-A"]);
    git(tmp, ["commit", "-q", "-m", "base"]);
    const baseSha = git(tmp, ["rev-parse", "HEAD"]).trim();

    git(tmp, ["checkout", "-q", "-b", "feature"]);
    fs.writeFileSync(path.join(tmp, "schema.prisma"), headSchema);
    for (const [name, contents] of Object.entries(extraHeadFiles)) write(tmp, name, contents);
    git(tmp, ["add", "-A"]);
    git(tmp, ["commit", "-q", "-m", "head"]);

    try {
      const stdout = execFileSync("node", [SCRIPT, "--base", baseSha], { cwd: tmp, encoding: "utf8" });
      return { code: 0, output: stdout };
    } catch (err) {
      const stdout = err.stdout || "";
      const stderr = err.stderr || "";
      return { code: err.status, output: stdout + stderr };
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

describe("schema-comment-check", () => {
  test("no prisma change in diff -> passes with 'nothing to enforce'", () => {
    const schema = "model User {\n  id String @id\n}\n";
    const { code, output } = runGate(schema, schema, { "README.md": "unrelated change\n" });
    assert.equal(code, 0);
    assert.match(output, /nothing to enforce/);
  });

  test("added column without /// doc comment fails", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head = "model User {\n  id String @id\n  email String\n}\n";
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0);
    assert.match(output, /FAIL/);
    assert.match(output, /email/);
  });

  test("added column with leading /// doc comment passes", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head = "model User {\n  id String @id\n  /// user email address\n  email String\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0);
    assert.match(output, /PASS/);
  });

  test("added column with trailing /// doc comment passes", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head = "model User {\n  id String @id\n  email String /// user email\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0);
    assert.match(output, /PASS/);
  });

  test("pre-existing uncommented column is grandfathered", () => {
    const base = "model User {\n  id String @id\n  name String\n}\n";
    const head = "model User {\n  id String @id\n  name String\n  /// email\n  email String\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0);
    assert.match(output, /PASS/);
  });

  test("relation navigation field is not a column and is skipped", () => {
    const base = "model Org {\n  id String @id\n}\n\nmodel User {\n  id String @id\n}\n";
    const head = "model Org {\n  id String @id\n}\n\nmodel User {\n  id String @id\n  org Org\n}\n";
    const { code } = runGate(base, head);
    assert.equal(code, 0);
  });

  test("FK scalar field is enforced even though it rides next to a relation", () => {
    const base = "model Org {\n  id String @id\n}\n\nmodel User {\n  id String @id\n}\n";
    const head =
      "model Org {\n  id String @id\n}\n\nmodel User {\n  id String @id\n  orgId String\n}\n";
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0);
    assert.match(output, /orgId/);
  });

  test("unbalanced brace inside a /// comment does not close the model early or fail open", () => {
    // The /// line's stray '}' must not be mistaken for the model's closing
    // brace (which would end brace-depth tracking early and grandfather
    // everything after it). Put a documented field directly after the
    // brace-carrying comment (so that comment's doc-attribution goes to
    // THAT field, not to `status`), then an undocumented `status` field
    // further down — it must still be caught.
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n" +
      "  id String @id\n" +
      "  /// note: describes a JSON envelope like this: }\n" +
      "  email String /// has its own trailing doc\n" +
      "  status String\n" +
      "}\n";
    const { code, output } = runGate(base, head);
    assert.notEqual(
      code,
      0,
      `expected non-zero exit catching undocumented 'status' column, got code ${code} with output:\n${output}`,
    );
    assert.match(
      output,
      /status/,
      `expected output to mention 'status' as the violating field, got:\n${output}`,
    );
    assert.doesNotMatch(
      output,
      /CANNOT VERIFY/,
      `gate emitted CANNOT VERIFY instead of correctly catching the undocumented column — this is a real finding, not a test bug. Output:\n${output}`,
    );
  });

  test("added nullable column whose doc mentions null passes", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n  id String @id\n  /// Timestamp the account was closed. Null while the account is still open.\n  closedAt DateTime?\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("added nullable column whose doc does NOT mention null fails, distinct from CANNOT VERIFY", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n  id String @id\n  /// Timestamp the account was closed.\n  closedAt DateTime?\n}\n";
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0);
    assert.match(output, /closedAt/);
    assert.doesNotMatch(
      output,
      /CANNOT VERIFY/,
      `gate emitted CANNOT VERIFY instead of the null-semantics finding. Output:\n${output}`,
    );
  });

  test("added NON-nullable column whose doc does not mention null passes (rule does not leak)", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n  id String @id\n  /// Timestamp the account was closed.\n  closedAt DateTime\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("multi-line leading /// block, only a later line mentions null, passes", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n  id String @id\n" +
      "  /// Timestamp the account was closed.\n" +
      "  /// Null while the account is still open.\n" +
      "  closedAt DateTime?\n" +
      "}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("trailing /// on the field line mentioning null passes", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      "model User {\n  id String @id\n  closedAt DateTime? /// null means the account is still open\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("pre-existing untouched nullable column with a null-silent doc is grandfathered", () => {
    const base =
      "model User {\n  id String @id\n  /// Timestamp the account was closed.\n  closedAt DateTime?\n}\n";
    const head =
      "model User {\n  id String @id\n  /// Timestamp the account was closed.\n  closedAt DateTime?\n  /// user email\n  email String\n}\n";
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("touched Unsupported(\"tsvector\")? column without null-mentioning doc fails", () => {
    const base = "model User {\n  id String @id\n}\n";
    const head =
      'model User {\n  id String @id\n  /// Full-text search vector.\n  searchVector Unsupported("tsvector")?\n}\n';
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /searchVector/);
  });
});

// ---------------------------------------------------------------------------
// Enums: `///` on declarations and members, plus COMMENT ON TYPE parity.
//
// Postgres has no per-label comment — COMMENT ON ENUM LABEL and COMMENT ON
// VALUE are both syntax errors — so the parity rule asks for one type-level
// statement carrying the folded member descriptions. These tests pin that
// shape, and pin the two ways it must NOT be satisfiable: by a comment written
// in an earlier migration, and on a non-Postgres datasource.
// ---------------------------------------------------------------------------

const PG = 'datasource db {\n  provider = "postgresql"\n  url = env("DATABASE_URL")\n}\n\n';
const MYSQL = 'datasource db {\n  provider = "mysql"\n  url = env("DATABASE_URL")\n}\n\n';
const MIGRATION = "migrations/20260801000000_enum/migration.sql";

describe("schema-comment-check: enums", () => {
  test("added enum member without /// doc comment fails", () => {
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  NAY\n}\n`;
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /Vote\.NAY/);
  });

  test("added enum member with /// but no COMMENT ON TYPE in the migration fails", () => {
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  /// Voted against.\n  NAY\n}\n`;
    const { code, output } = runGate(base, head, {
      [MIGRATION]: 'ALTER TYPE "Vote" ADD VALUE \'NAY\';\n',
    });
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /COMMENT ON TYPE/);
    assert.match(output, /Vote/);
  });

  test("added enum member with /// and a COMMENT ON TYPE in the migration passes", () => {
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  /// Voted against.\n  NAY\n}\n`;
    const { code, output } = runGate(base, head, {
      [MIGRATION]:
        'ALTER TYPE "Vote" ADD VALUE \'NAY\';\nCOMMENT ON TYPE "Vote" IS \'How a legislator voted. YEA: in favour. NAY: against.\';\n',
    });
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("new enum declaration without a /// doc comment fails", () => {
    const base = `${PG}model User {\n  id String @id\n}\n`;
    const head = `${PG}model User {\n  id String @id\n}\n\nenum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const { code, output } = runGate(base, head, {
      [MIGRATION]: 'COMMENT ON TYPE "Vote" IS \'How a legislator voted. YEA: in favour.\';\n',
    });
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /Vote/);
  });

  test("pre-existing untouched enum is grandfathered", () => {
    const base = `${PG}enum Vote {\n  YEA\n  NAY\n}\n\nmodel User {\n  id String @id\n}\n`;
    const head = `${PG}enum Vote {\n  YEA\n  NAY\n}\n\nmodel User {\n  id String @id\n  /// User email address.\n  email String\n}\n`;
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("a COMMENT ON TYPE in an EARLIER migration does not satisfy parity for a new member", () => {
    // The whole point of scoping parity to added lines: a comment written when
    // the enum had two members says nothing about the third, but it is sitting
    // right there in the migrations tree looking like compliance.
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  /// Voted against.\n  NAY\n}\n`;
    const { code, output } = runGate(
      base,
      head,
      { [MIGRATION]: 'ALTER TYPE "Vote" ADD VALUE \'NAY\';\n' },
      { "migrations/20260101000000_init/migration.sql": 'COMMENT ON TYPE "Vote" IS \'YEA: in favour.\';\n' },
    );
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /COMMENT ON TYPE/);
  });

  test("non-Postgres datasource skips the COMMENT ON parity rule but still needs ///", () => {
    const base = `${MYSQL}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${MYSQL}enum Vote {\n  /// Voted in favour.\n  YEA\n  /// Voted against.\n  NAY\n}\n`;
    const { code, output } = runGate(base, head);
    assert.equal(code, 0, `expected PASS, got code ${code} with output:\n${output}`);
    assert.match(output, /PASS/);
  });

  test("@@map'd enum expects the COMMENT ON TYPE to use the mapped Postgres type name", () => {
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n\n  @@map("vote_value")\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  /// Voted against.\n  NAY\n\n  @@map("vote_value")\n}\n`;

    const wrongName = runGate(base, head, {
      [MIGRATION]: 'COMMENT ON TYPE "Vote" IS \'…\';\n',
    });
    assert.notEqual(wrongName.code, 0, `expected non-zero exit, got:\n${wrongName.output}`);
    assert.match(wrongName.output, /vote_value/);

    const rightName = runGate(base, head, {
      [MIGRATION]: 'COMMENT ON TYPE "vote_value" IS \'YEA: in favour. NAY: against.\';\n',
    });
    assert.equal(rightName.code, 0, `expected PASS, got code ${rightName.code} with output:\n${rightName.output}`);
  });

  test("unclassifiable touched line inside an enum fails CANNOT VERIFY, not silently", () => {
    const base = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n}\n`;
    const head = `${PG}enum Vote {\n  /// Voted in favour.\n  YEA\n  NAY = "nay"\n}\n`;
    const { code, output } = runGate(base, head);
    assert.notEqual(code, 0, `expected non-zero exit, got code ${code} with output:\n${output}`);
    assert.match(output, /CANNOT VERIFY/);
  });
});
