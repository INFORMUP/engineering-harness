// Self-test for modules/taskflow/.github/scripts/taskflow-link.mjs
//
// Zero npm deps: node:test + node:assert/strict. The script's network calls go
// through an injected fetch, so the whole thing runs offline — every case here
// asserts on the exit code and the recorded requests.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = pathToFileURL(
  path.join(__dirname, "..", "modules", "taskflow", ".github", "scripts", "taskflow-link.mjs"),
).href;

const { extractSection, parseTaskRef, taskRefFromBranch, resolveTaskIntent, run } =
  await import(SCRIPT);

const TASK_UUID = "d0adefef-b323-4195-bc8f-21b45adc364b";

const ENV = {
  TASKFLOW_API_URL: "https://taskflow.example.org",
  TASKFLOW_API_TOKEN: "token",
  PR_URL: "https://github.com/acme/widget/pull/42",
  PR_TITLE: "feat: add a widget",
  PR_AUTHOR: "junior-dev",
  HEAD_REF: "feat/FEAT-12-add-widget",
};

/** A fetch stub that records calls and replays canned responses in order. */
function stubFetch(responses) {
  const calls = [];
  const queue = [...responses];
  const impl = async (url, init) => {
    calls.push({ url, method: init?.method ?? "GET", body: init?.body, init });
    const next = queue.shift();
    if (!next) throw new Error(`unexpected request: ${url}`);
    if (next instanceof Error) throw next;
    return {
      ok: next.status < 400,
      status: next.status,
      json: async () => next.body ?? null,
    };
  };
  return { impl, calls };
}

const taskLookup = {
  status: 200,
  body: { data: [{ id: TASK_UUID, displayId: "FEAT-12" }] },
};

/** Run the script with a stubbed fetch; returns { code, calls, logs }. */
async function runScript(env, responses) {
  const { impl, calls } = stubFetch(responses);
  const logs = [];
  const code = await run({
    env: { ...ENV, ...env },
    fetchImpl: impl,
    log: (m) => logs.push(m),
  });
  return { code, calls, logs: logs.join("\n") };
}

describe("section parsing", () => {
  test("returns null when the heading is absent, empty when unfilled", () => {
    assert.equal(extractSection("## What / Why\nstuff", "## Task"), null);
    assert.equal(extractSection("## Task\n<!-- hint -->\n## Reuse\nx", "## Task"), "");
  });

  test("stops at the next heading", () => {
    assert.equal(extractSection("## Task\nFEAT-12\n## Reuse\nNone", "## Task"), "FEAT-12");
  });
});

describe("task references", () => {
  test("reads a display ID, a UUID, or a pasted task URL", () => {
    assert.equal(parseTaskRef("implements FEAT-12"), "FEAT-12");
    assert.equal(parseTaskRef(TASK_UUID), TASK_UUID);
    assert.equal(
      parseTaskRef(`https://taskflow.example.org/tasks/${TASK_UUID}`),
      TASK_UUID,
    );
  });

  test("a URL wins over a display ID in the same sentence", () => {
    // Both appear when someone pastes a link and types the ID; the URL is the
    // unambiguous one, so it must not lose to whichever matched first.
    assert.equal(
      parseTaskRef(`FEAT-12 — https://taskflow.example.org/tasks/${TASK_UUID}`),
      TASK_UUID,
    );
  });

  test("branch names yield the display ID, uppercased", () => {
    assert.equal(taskRefFromBranch("feat/FEAT-12-add-widget"), "FEAT-12");
    assert.equal(taskRefFromBranch("fix/bug-7"), "BUG-7");
    assert.equal(taskRefFromBranch("chore/tidy-up"), null);
  });
});

describe("intent", () => {
  test("the body outranks the branch", () => {
    const intent = resolveTaskIntent({ section: "BUG-7", branch: "feat/FEAT-12-x" });
    assert.deepEqual(intent, { action: "link", ref: "BUG-7", source: "body" });
  });

  test("a declared 'None' with a reason skips linking", () => {
    const intent = resolveTaskIntent({ section: "None — typo in a comment", branch: "chore/x" });
    assert.equal(intent.action, "skip");
  });

  test("'None' beats a task-bearing branch", () => {
    // Otherwise an author who deliberately declined would still get a link,
    // and would have no way to say "this branch's ID isn't what I meant".
    const intent = resolveTaskIntent({
      section: "None — reverting my own typo",
      branch: "feat/FEAT-12-x",
    });
    assert.equal(intent.action, "skip");
  });

  test("'None' with no reason fails", () => {
    assert.equal(resolveTaskIntent({ section: "None", branch: "chore/x" }).action, "fail");
    assert.equal(resolveTaskIntent({ section: "n/a", branch: "chore/x" }).action, "fail");
  });

  test("an empty section falls back to the branch rather than failing", () => {
    const intent = resolveTaskIntent({ section: "", branch: "feat/FEAT-12-x" });
    assert.deepEqual(intent, { action: "link", ref: "FEAT-12", source: "branch" });
  });

  test("a missing section, or an empty one on a nameless branch, fails", () => {
    assert.equal(resolveTaskIntent({ section: null, branch: "feat/FEAT-12-x" }).action, "fail");
    assert.equal(resolveTaskIntent({ section: "", branch: "chore/x" }).action, "fail");
  });
});

describe("linking", () => {
  test("resolves the display ID and posts the PR", async () => {
    const { code, calls } = await runScript(
      { PR_BODY: "## Task\nFEAT-12\n" },
      [taskLookup, { status: 201, body: {} }],
    );
    assert.equal(code, 0);
    assert.match(calls[0].url, /\/api\/v1\/tasks\?displayId=FEAT-12/);
    assert.equal(calls[1].url, `https://taskflow.example.org/api/v1/tasks/${TASK_UUID}/pull-requests`);
    assert.equal(calls[1].method, "POST");
    assert.deepEqual(JSON.parse(calls[1].body), {
      url: ENV.PR_URL,
      title: ENV.PR_TITLE,
      author: ENV.PR_AUTHOR,
      state: "open",
    });
    assert.match(calls[1].init.headers.Authorization, /^Bearer /);
  });

  test("a UUID needs no lookup", async () => {
    const { code, calls } = await runScript(
      { PR_BODY: `## Task\n${TASK_UUID}\n` },
      [{ status: 200, body: {} }],
    );
    assert.equal(code, 0);
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /\/pull-requests$/);
  });

  test("falls back to the branch when the section is only a hint comment", async () => {
    const { code, calls } = await runScript(
      { PR_BODY: "## Task\n<!-- FEAT-99 is just an example -->\n" },
      [taskLookup, { status: 200, body: {} }],
    );
    assert.equal(code, 0);
    assert.match(calls[0].url, /displayId=FEAT-12/);
  });

  test("an already-linked PR (200, not 201) still passes", async () => {
    const { code } = await runScript({ PR_BODY: "## Task\nFEAT-12\n" }, [
      taskLookup,
      { status: 200, body: {} },
    ]);
    assert.equal(code, 0);
  });

  test("no task claimed and none derivable fails without calling the API", async () => {
    const { code, calls, logs } = await runScript(
      { PR_BODY: "## Task\n\n", HEAD_REF: "chore/tidy" },
      [],
    );
    assert.equal(code, 1);
    assert.equal(calls.length, 0);
    assert.match(logs, /::error::/);
  });

  test("a declined task links nothing", async () => {
    const { code, calls } = await runScript(
      { PR_BODY: "## Task\nNone — comment-only change\n" },
      [],
    );
    assert.equal(code, 0);
    assert.equal(calls.length, 0);
  });

  test("an unresolvable task ID fails the check", async () => {
    const { code, logs } = await runScript({ PR_BODY: "## Task\nFEAT-999\n" }, [
      { status: 200, body: { data: [] } },
    ]);
    assert.equal(code, 1);
    assert.match(logs, /no task "FEAT-999"/);
  });

  test("a repo not registered on the task's project fails the check", async () => {
    const { code, logs } = await runScript({ PR_BODY: "## Task\nFEAT-12\n" }, [
      taskLookup,
      { status: 400, body: { error: { code: "REPO_NOT_ON_TASK_PROJECT", message: "nope" } } },
    ]);
    assert.equal(code, 1);
    assert.match(logs, /REPO_NOT_ON_TASK_PROJECT/);
  });

  test("an unreachable TaskFlow warns and passes", async () => {
    // The tracker sleeps overnight in some deployments. Blocking a PR on that
    // would make the module a liability rather than a gate.
    const { code, logs } = await runScript({ PR_BODY: "## Task\nFEAT-12\n" }, [
      new Error("ECONNREFUSED"),
    ]);
    assert.equal(code, 0);
    assert.match(logs, /::warning::TaskFlow unreachable/);
  });

  test("a 5xx warns and passes; a 4xx does not", async () => {
    const down = await runScript({ PR_BODY: "## Task\nFEAT-12\n" }, [
      { status: 503, body: null },
    ]);
    assert.equal(down.code, 0);

    const denied = await runScript({ PR_BODY: "## Task\nFEAT-12\n" }, [
      { status: 403, body: { error: { code: "FORBIDDEN", message: "scope" } } },
    ]);
    assert.equal(denied.code, 1);
  });

  test("missing credentials (fork PR) warn but keep the gate", async () => {
    const linkable = await runScript(
      { PR_BODY: "## Task\nFEAT-12\n", TASKFLOW_API_TOKEN: "" },
      [],
    );
    assert.equal(linkable.code, 0);
    assert.match(linkable.logs, /::warning::.*not available/);

    // ...but a PR that claims nothing still fails, credentials or not.
    const empty = await runScript(
      { PR_BODY: "## Task\n\n", HEAD_REF: "chore/tidy", TASKFLOW_API_TOKEN: "" },
      [],
    );
    assert.equal(empty.code, 1);
  });
});
