# TaskFlow module

**Opt-in.** The base template is tracker-agnostic; this module wires a repo to a
[TaskFlow](https://github.com/INFORMUP/TaskFlow) instance. Install it only in
repos whose work is tracked there.

## What it gives you

| Guarantee | Mechanism |
|---|---|
| Every PR states which tracked item it implements, or declines one with a reason | `## Task` section + the `taskflow` check |
| A PR that implements a task is linked to it in the tracker, without anyone remembering to | `taskflow-link.mjs`, deriving the task from the branch name |
| The tracker can answer "shipped but never closed" | falls out of the above — TaskFlow refreshes each linked PR's state hourly |

The gate and the link are deliberately separate concerns. The gate is offline,
mechanical, and blocking. The link is a network call to a service that can be
down, so it never blocks: an unreachable TaskFlow logs a warning and passes.

## Prerequisites

1. **The repo is registered on the project in TaskFlow** (owner/name under the
   project's repositories). Linking resolves the repo from the PR URL, and a
   URL pointing at an unregistered repo is refused — `REPO_NOT_ON_TASK_PROJECT`.
2. **An agent API token** with the `tasks:write` scope, minted from TaskFlow's
   Agents UI. Use an agent identity, not a person's token: every link this
   workflow creates is attributed to whoever the token belongs to.

## Install

```bash
scripts/install-module.sh taskflow ~/src/your-repo
```

Then the manual follow-ups the installer prints:

1. **Splice the `## Task` section** from `PULL_REQUEST_TEMPLATE.snippet.md` into
   the repo's `.github/PULL_REQUEST_TEMPLATE.md` (the installer never overwrites
   an existing template), and delete the snippet.
2. **Splice `CLAUDE-taskflow.md`** into the repo's root `CLAUDE.md`, then delete
   it from the target.
3. **Configure the workflow** in the repo's settings:
   - variable `TASKFLOW_API_URL` — e.g. `https://taskflow.example.org`
   - secret `TASKFLOW_API_TOKEN` — the agent token above
   An org-level variable and secret cover every repo at once, which is the point
   of doing it that way rather than per repo.
4. **Add `taskflow` to the required checks** so the gate is binding:
   `scripts/install-ruleset.sh ORG/REPO <existing-checks>,taskflow`

Without step 3 the module still gates — it just can't link, and says so in the
job log on every PR. That is a reasonable way to run it for a week before
handing out a token.

## Behavior in detail

Where the task reference comes from, in order:

1. the PR body's `## Task` section — a display ID (`FEAT-12`), a task URL, or a
   UUID;
2. `None — <reason>` in that section, which links nothing and passes;
3. failing both, the branch name (`feat/FEAT-12-add-widget`);
4. failing all of those, the check fails and tells the author what to write.

The body beats the branch on purpose: editing the body is how an author corrects
a wrong link, and an author who wrote a reference outranks a naming convention.
The decline beats the branch for the same reason — otherwise someone declaring
"no task here" would be overruled by their own branch name.

An **empty** section is not a failure. On a conventionally-named branch the task
is already known, and making someone retype it is how a gate turns into a box
people paste past.

Failure modes and how they're treated:

| Situation | Result |
|---|---|
| No task named, and the branch name doesn't carry one either | **fail** — author fixes the body |
| `None` with no reason | **fail** — the escape hatch requires the reason |
| Task ID doesn't resolve, or the repo isn't on the task's project | **fail** — a wrong link is worse than none |
| TaskFlow unreachable or 5xx (it sleeps overnight in some deployments) | **pass with a warning** — re-run the job to link |
| Fork PR (GitHub withholds secrets by design) | **pass with a warning** — the gate still applied |

Linking is idempotent: re-running the job on an already-linked PR is a no-op.

**Fork PRs are not linked, and that is deliberate.** Reading the secret from a
fork's PR would mean `pull_request_target`, which runs the *base* repo's
workflow with secrets against untrusted code. Not worth a tracker link.
