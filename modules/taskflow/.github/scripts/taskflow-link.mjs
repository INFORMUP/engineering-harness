#!/usr/bin/env node
/**
 * Ties a pull request to the tracked work item it implements.
 *
 * Two jobs, in this order, because the second one is best-effort and the first
 * one is not:
 *
 *  1. GATE — the PR body's "## Task" section must name a task, or explicitly
 *     decline one with a reason. Mechanical, offline, and the only part that
 *     can fail the check on the author's behalf.
 *  2. LINK — POST the PR to that task in TaskFlow, so the tracker knows the
 *     work exists. Idempotent; re-running a merged PR's job is harmless.
 *
 * Why link at all: TaskFlow refreshes each linked PR's open/merged/closed
 * state on its own. A PR nobody links is invisible to every "shipped but never
 * closed" query the tracker can answer — so the tracking is only as good as
 * the linking, and linking by hand is exactly what gets forgotten.
 *
 * The task reference is taken from the body when the author gave one, and
 * otherwise derived from the branch name, since the convention already puts it
 * there (feat/FEAT-123-add-widget). Body beats branch: an author who wrote the
 * section is more authoritative than a naming convention.
 *
 * Environment (all supplied by the workflow):
 *   TASKFLOW_API_URL     base URL, e.g. https://taskflow.example.org
 *   TASKFLOW_API_TOKEN   agent API token with the tasks:write scope
 *   PR_BODY, PR_URL, PR_TITLE, PR_AUTHOR, HEAD_REF
 */

const TASK_SECTION_HEADING = "## Task";

/**
 * A declined task ("None — ...") needs a real reason, not the word alone.
 * Short enough to allow "typo fix", long enough to reject "n/a" and ".".
 */
const MIN_DECLINE_REASON_CHARS = 8;

const UUID_RE =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
/** Display IDs look like FEAT-12 / BUG-7 — a flow prefix and a number. */
const DISPLAY_ID_RE = /\b([A-Z]{2,})-(\d+)\b/;
/** A pasted task URL: .../tasks/<uuid>. */
const TASK_URL_RE = new RegExp(`/tasks/(${UUID_RE.source})`, "i");
/** Branch names carry the display ID by convention: feat/FEAT-123-slug. */
const BRANCH_DISPLAY_ID_RE = /(?:^|[/_-])([A-Za-z]{2,})-(\d+)(?:[/_-]|$)/;
const DECLINE_RE = /^(none|no task|n\/a)\b/i;

/** Pull one "## Heading" section out of a Markdown body, comments stripped. */
export function extractSection(body, heading) {
  const lines = String(body ?? "").split("\n");
  const start = lines.findIndex((line) => line.trim() === heading);
  if (start === -1) return null;

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      end = i;
      break;
    }
  }
  return lines
    .slice(start + 1, end)
    .join("\n")
    .replace(/<!--[\s\S]*?-->/g, "")
    .trim();
}

/** First task reference in some text: a task URL, a bare UUID, or FEAT-12. */
export function parseTaskRef(text) {
  const input = String(text ?? "");
  const url = input.match(TASK_URL_RE);
  if (url) return url[1];
  const uuid = input.match(UUID_RE);
  if (uuid) return uuid[0];
  const display = input.match(DISPLAY_ID_RE);
  if (display) return `${display[1]}-${display[2]}`;
  return null;
}

/** feat/FEAT-123-add-widget -> FEAT-123. Null when the branch says nothing. */
export function taskRefFromBranch(branch) {
  const m = String(branch ?? "").match(BRANCH_DISPLAY_ID_RE);
  return m ? `${m[1].toUpperCase()}-${m[2]}` : null;
}

/**
 * Decide what this PR is claiming about its task, from the body section and
 * the branch name. Returns one of:
 *   { action: "link", ref, source }   link it to that task
 *   { action: "skip", reason }        no task, declared and justified
 *   { action: "fail", message }       the author has to say something
 */
export function resolveTaskIntent({ section, branch }) {
  if (section === null) {
    return {
      action: "fail",
      message: `PR body has no "${TASK_SECTION_HEADING}" section. Add it (see .github/PULL_REQUEST_TEMPLATE.md).`,
    };
  }
  // A filled-in section is the author speaking, so it is read first and wins.
  // An empty one is not a failure yet: the branch name usually already carries
  // the task, and making people retype it is how a gate becomes a formality
  // people paste past.
  if (section) {
    const fromBody = parseTaskRef(section);
    if (fromBody) return { action: "link", ref: fromBody, source: "body" };

    if (DECLINE_RE.test(section)) {
      const reason = section.replace(DECLINE_RE, "").replace(/^[\s—–:-]+/, "");
      if (reason.length < MIN_DECLINE_REASON_CHARS) {
        return {
          action: "fail",
          message: `"${TASK_SECTION_HEADING}" declines a task without saying why. Write "None — <reason>".`,
        };
      }
      return { action: "skip", reason };
    }
  }

  const fromBranch = taskRefFromBranch(branch);
  if (fromBranch) return { action: "link", ref: fromBranch, source: "branch" };

  return {
    action: "fail",
    message: `"${TASK_SECTION_HEADING}" names no task and none could be read from the branch name "${branch}". Name the task this PR implements (FEAT-12, a task URL, or a UUID), or write "None — <why this work has no task>".`,
  };
}

/** Thrown for a definite, author-fixable API answer (bad id, unknown repo). */
class TaskflowClientError extends Error {}
/** Thrown when TaskFlow itself couldn't answer — never the author's fault. */
class TaskflowUnavailableError extends Error {}
/** Thrown when the repo's own stored credential is what TaskFlow refused. */
class TaskflowCredentialError extends Error {}

async function apiFetch({ apiUrl, token, path, method = "GET", body, fetchImpl }) {
  let res;
  try {
    res = await fetchImpl(`${apiUrl.replace(/\/$/, "")}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  } catch (err) {
    throw new TaskflowUnavailableError(`could not reach TaskFlow: ${err.message}`);
  }

  const payload = await res.json().catch(() => null);
  if (res.ok) return payload;

  const detail = payload?.error?.code ?? `HTTP_${res.status}`;
  const message = payload?.error?.message ?? `request failed (${res.status})`;
  if (res.status >= 500) {
    throw new TaskflowUnavailableError(`${detail}: ${message}`);
  }
  if (res.status === 401 || res.status === 403) {
    throw new TaskflowCredentialError(`${detail}: ${message}`);
  }
  throw new TaskflowClientError(`${detail}: ${message}`);
}

/** Display IDs are for humans; the API routes on UUIDs. */
export async function resolveTaskId({ apiUrl, token, ref, fetchImpl }) {
  if (UUID_RE.test(ref) && ref.length === 36) return ref;

  const want = ref.toUpperCase();
  const payload = await apiFetch({
    apiUrl,
    token,
    path: `/api/v1/tasks?displayId=${encodeURIComponent(want)}&limit=2`,
    fetchImpl,
  });
  const hit = (payload?.data ?? []).find(
    (t) => String(t.displayId ?? "").toUpperCase() === want,
  );
  if (!hit) {
    throw new TaskflowClientError(
      `no task "${ref}" — check the reference, or paste the task URL instead (some flows' display IDs don't match their prefix)`,
    );
  }
  return hit.id;
}

/** Link the PR. The endpoint is idempotent: 201 on create, 200 if it existed. */
export async function linkPullRequest({ apiUrl, token, ref, pr, fetchImpl }) {
  const taskId = await resolveTaskId({ apiUrl, token, ref, fetchImpl });
  await apiFetch({
    apiUrl,
    token,
    path: `/api/v1/tasks/${taskId}/pull-requests`,
    method: "POST",
    body: { url: pr.url, title: pr.title, author: pr.author, state: "open" },
    fetchImpl,
  });
  return taskId;
}

export async function run({ env, fetchImpl = fetch, log = console.log }) {
  const intent = resolveTaskIntent({
    section: extractSection(env.PR_BODY, TASK_SECTION_HEADING),
    branch: env.HEAD_REF,
  });

  if (intent.action === "fail") {
    log(`::error::${intent.message}`);
    return 1;
  }
  if (intent.action === "skip") {
    log(`PASS: no task claimed, with a reason — "${intent.reason}"`);
    return 0;
  }

  log(`Task ${intent.ref} (from the PR ${intent.source})`);

  // Fork PRs run without secrets, by GitHub's design. The gate above already
  // passed, and a contributor cannot fix a credential they can't have — so
  // report the un-linked PR rather than failing them for it.
  if (!env.TASKFLOW_API_URL || !env.TASKFLOW_API_TOKEN) {
    log(
      "::warning::TASKFLOW_API_URL / TASKFLOW_API_TOKEN not available (fork PR, or the module isn't configured) — gate passed, PR not linked.",
    );
    return 0;
  }

  try {
    const taskId = await linkPullRequest({
      apiUrl: env.TASKFLOW_API_URL,
      token: env.TASKFLOW_API_TOKEN,
      ref: intent.ref,
      pr: { url: env.PR_URL, title: env.PR_TITLE, author: env.PR_AUTHOR },
      fetchImpl,
    });
    log(`PASS: linked ${env.PR_URL} to task ${taskId}`);
    return 0;
  } catch (err) {
    if (err instanceof TaskflowUnavailableError) {
      // The tracker being down is not a code-review finding. Say so loudly and
      // let the PR through — re-run this job once TaskFlow is back to link it.
      log(`::warning::TaskFlow unreachable — ${err.message}. Re-run this job to link the PR.`);
      return 0;
    }
    if (err instanceof TaskflowCredentialError) {
      // Same reasoning as the outage above, and for the same reason it must not
      // block: a wrong or expired secret fails every PR in the repo identically,
      // on something only a repo admin can put right. A check that no author can
      // ever turn green is a check that gets switched off, taking the offline
      // gate — the half that does work — with it.
      log(
        `::warning::TaskFlow rejected this repo's credential — ${err.message}. ` +
          `The gate passed but the PR was NOT linked: a repo admin should refresh the ` +
          `TASKFLOW_API_TOKEN secret, then re-run this job.`,
      );
      return 0;
    }
    log(`::error::could not link this PR — ${err.message}`);
    return 1;
  }
}

const invokedDirectly =
  process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
  process.exitCode = await run({ env: process.env });
}
