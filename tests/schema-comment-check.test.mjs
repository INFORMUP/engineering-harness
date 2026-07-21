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
function runGate(baseSchema, headSchema, extraHeadFiles = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "schema-gate-"));
  try {
    git(tmp, ["init", "-q"]);
    git(tmp, ["config", "user.email", "test@example.com"]);
    git(tmp, ["config", "user.name", "Test"]);
    git(tmp, ["config", "commit.gpgsign", "false"]);

    fs.writeFileSync(path.join(tmp, "schema.prisma"), baseSchema);
    git(tmp, ["add", "-A"]);
    git(tmp, ["commit", "-q", "-m", "base"]);
    const baseSha = git(tmp, ["rev-parse", "HEAD"]).trim();

    git(tmp, ["checkout", "-q", "-b", "feature"]);
    fs.writeFileSync(path.join(tmp, "schema.prisma"), headSchema);
    for (const [name, contents] of Object.entries(extraHeadFiles)) {
      fs.writeFileSync(path.join(tmp, name), contents);
    }
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
});
