# CLAUDE.md section for the TaskFlow module

Splice the section below into the target repo's root `CLAUDE.md`, next to the
Worklog section (which already draws the worklog-vs-task line), then delete
this file from the target.

---

## Tracking work in TaskFlow
- **Not every PR needs a task.** A typo fix, a comment, a dependency bump nobody
  scheduled — those are PRs, not deliverables. What every PR needs is an
  *answer*: name the task in the PR's `## Task` section, or write
  `None — <reason>`. The `taskflow` check enforces that a claim was made, never
  which claim it is.
- **A PR that implements a task must link to it**, because linking is what makes
  the work visible to everyone not reading this PR. TaskFlow keeps each linked
  PR's open/merged/closed state current on its own, so the tracker can answer
  "what shipped but was never closed out" — but only for PRs somebody linked.
  An unlinked PR is invisible to that question forever.
- **You usually get the link for free.** Name the branch `feat/FEAT-12-slug` and
  the check reads the task out of it. Filling in `## Task` overrides the branch,
  which is how you fix a mis-derived link — edit the body and the check re-runs.
- **When the display ID doesn't resolve**, paste the task URL or UUID instead.
  Some flows' tasks carry a display ID whose prefix doesn't match the flow you'd
  guess from, and the lookup is exact.
- **Which work deserves a task at all** is the same test as the worklog's:
  something outside this session has to act on it — scheduling, review, sign-off,
  or tracking it as a deliverable.
