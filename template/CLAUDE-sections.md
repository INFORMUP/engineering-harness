# CLAUDE.md sections to splice into the target repo

Copy the sections below into the target repo's root `CLAUDE.md` (create it if
absent). They are the agent-facing half of the harness: CI enforces the
mechanical rules; these sections make agents *generate* conforming work
instead of having it bounced.

---

## Definition of Done
Every implementation PR must satisfy all of these before requesting review. Agents treat this as a checklist; automated review re-verifies it.

1. **Lint + typecheck clean** in every touched package.
2. **Tests accompany the behavior change** — including edge cases (boundaries, empty/null, error paths) and an access-denied case for each authorization rule touched. Where practical, prove the test by reverting the implementation and watching it fail.
   - **UI that fetches also tests the failed fetch.** A component or page that calls the API needs a case where that call rejects, asserting what the user sees — the error message, the retry affordance, the empty state that isn't an endless spinner. Mocking the client to always resolve tests the request, not the behavior. This is called out separately because it is the rule's most-skipped clause: measured across three INFORMUP frontends in July 2026, failure cases ran 6–11% of all frontend cases against 18–34% on the backends, and the gap was almost entirely *failed requests* — data-shape edges (empty list, absent field, tied counts) were covered reasonably everywhere.
   - **A denial asserted as a return value counts.** `expect(canEdit).toBe(false)` is an unhappy-path test as surely as one expecting a 403, and a predicate-style permission suite full of `cannot …` cases is thorough coverage even with no thrown error in sight. Don't add a fake throw to satisfy a reviewer — or a grep — that is pattern-matching on `toThrow`.
3. **Bug fixes carry a regression test** that reproduces the reported failure and failed before the fix (paste the red→green evidence in *Verification evidence*).
4. **Docs updated in the same PR** — see [docs/README.md](docs/README.md) for which doc owns what. "None — no behavior change" is a valid answer; a stale domain doc is not.
5. **Conventional-Commit PR title** (enforced by the `commitlint` workflow; with squash-only merges the title becomes the mainline commit message).
6. **Atomic size**: ≤ 500 changed lines and ≤ 5 files (lockfiles, generated paths, and `docs/` excluded — enforced by the `pr-gates` workflow). Split before you ask for `size-override`.
7. **No unexplained suppressions.** Any lint-disable, type-suppression, skipped test, or coverage-ignore added by the PR carries an inline `-- reason: <justification>` (temporary ones link a tracked task). Focused tests (`.only`) never merge.
8. **Reuse before rebuild.** Before writing a new helper, service, or class, consult [docs/inventory.md](docs/inventory.md) (the generated reuse index) and grep for existing implementations. New exported symbols in the reuse surface must be declared in the PR's *Reuse* section with what you searched and why existing code doesn't fit — deliberate duplication is acceptable *when stated*; accidental duplication is a request-changes. Extending an existing module beats creating a parallel one.

## Code Style
- **[docs/style.md](docs/style.md) is the house style guide** — it inherits from a public parent guide and records only house deviations and judgment rules. Precedence: formatter → linter → house guide → parent guide.
- **Agents never edit `docs/style.md`.** Propose style changes as a tracked task instead; humans decide and land them via a `style-update`-labeled PR.

## Commit Workflow
- **Session setup:** run `./install-pre-commit-hooks.sh` before your first commit in a session (idempotent). It activates the git hooks in `.githooks/`, so commits get the same formatting / type-check / reuse-inventory-sync gates CI enforces — caught locally instead of as a red build.
- Run the affected package's tests before committing. Hooks are the fast path; CI is the guarantee.
- **Commits on a protected branch are refused** by the same hook, before any of the quality gates run. Defaults to `main`, `master`, and `staging` — the last matters for repos that integrate on `staging` and promote to `main`, where both are off-limits. A repo needing a different set overrides it without editing the shared hook: `git config informup.protectedBranches "main develop"`. A detached HEAD is allowed on purpose, so rebases and bisects still work.
- No `--no-verify` and no force-push. The branch guard prints `--no-verify` as its escape hatch because it must be recoverable for a human in a genuine edge case; that is **not** licence for an agent to use it. If the guard fires, move the work to a worktree — that is what it is telling you to do.

## Worklog
- **`docs/worklog/` holds issues found in passing and the reasoning behind them** — one file per item, written **when the item is discovered**, not when work on it starts. Discovery-time is when the evidence is free; reconstructing it later costs an investigation and yields a worse entry. Resolved entries move to `docs/worklog/archive/` with a `YYYY-MM-DD-HHMM-` filename prefix (UTC); they are never deleted.
- **The entry records what a diff cannot**: the evidence (commands + output, `path:line`), why it matters, and **the approaches considered and rejected, with reasons**. That last part is the one that makes an old entry worth reading — it is how a wrong approach gets diagnosed afterward and how trends across entries surface.
- **Worklog vs. a TaskFlow task** — the test is not size, it's **whether someone outside the session must act on it**. TaskFlow if it needs scheduling, a review gate, acceptance criteria, or is tracked as a deliverable. Worklog for everything else, *including things that will never be done* — "looked at this, here's why it's fine" has no resting place in TaskFlow.
- **Promote by link, not by copy.** A graduating entry gets a TaskFlow task whose body cites the worklog path; the entry records the task id. TaskFlow owns status and scheduling, the repo owns evidence. Copying the reasoning into both means the current half lives in whichever was written last.
- **An entry belongs to the repo whose code it describes**, so it travels with that code and is greppable by an agent working there — not centralized in the umbrella repo.
- **Agents file and update entries; only humans resolve them.** Filing is not permission to act on the item, and it does not license a detour from the requested task.
- The worklog is *not* the "docs updated in the same PR" obligation in the Definition of Done — that's the domain docs in [docs/README.md](docs/README.md). A worklog entry is a record, not documentation of behavior.

## Architecture decisions (ADRs)
- **An ADR records a decision that is settled, binding on future work, and non-obvious from the code.** One file per decision in `docs/adr/`, started from `docs/adr/0000-template.md`: context, decision, **options considered with why each lost**, and consequences in both directions. Proposed while its PR is open, Accepted on merge. See [docs/adr/README.md](docs/adr/README.md) for the full test and worked examples.
- **Write one when any of these holds.** The typical categories — a new dependency, a schema change, a cross-module design, an auth/permission change — are where these usually land, but the categories are not the test:
  - **A deliberate constraint is indistinguishable from a bug.** A fail-closed default, a deliberately narrow gate, a check that looks redundant. **Weight this highest.** Code shows *what*, never *which alternative was rejected and why* — so without the record, someone eventually "fixes" the safety property. Every other trigger costs rediscovery; this one causes damage.
  - **The rejected alternative is the obvious move and is actively harmful.** When the naive fix makes things *worse* rather than merely different, the rejection is the load-bearing half and it lives nowhere in the diff.
  - **The decision spans modules or repos**, so no single file can carry it and it has no natural home in the code.
  - **You are re-deriving an answer you have reached before.** Re-litigation is the signal that the reasoning never got written down.
- **Don't write one** for a decision that is reversible, obvious from the code, or that nobody will revisit — and never one that only restates what the code already says. An ADR per routine dependency bump is noise, and noise is what stops the directory being read.
- **ADR vs. worklog vs. this file.** Worklog = an *open* question or an issue found in passing; the entry carries evidence and stays open until a human closes it. ADR = a *settled* decision, with the rejected options as its most valuable part. This file = a settled constraint whose reasoning is short enough to state in a bullet. Reach for an ADR when the *why* outgrows a bullet here but still has to be found at the moment someone is about to violate it — then leave a one-line pointer to it here, because this file is the one an agent reads every session.
- **Promote a resolved worklog entry by link, not by copy.** When an entry's resolution establishes a lasting constraint, the ADR states the constraint and the rejected option; the archived entry keeps the evidence and the dead ends. Same rule as worklog↔TaskFlow: two copies means the current one is whichever was written last.
- **Accepted ADRs are never edited.** A change of course is a *new* ADR; the only permitted edit to the old one is flipping its Status to `Superseded-by-NNNN`.

## Schema conventions
- **Every Prisma column carries a `///` doc comment.** Every model field that maps to a real DB column — including FK scalar columns (`organizationId String`) — gets a `///` doc comment that spells out any acronyms and states units (e.g. cents, milliseconds, percent). Relation navigation fields aren't columns and need no comment.
- **`///`, not `//`.** Only a `///` documentation comment rides into the generated client (as JSDoc) and can be mirrored to a Postgres `COMMENT ON COLUMN` so the description is readable straight from `psql \d+`. Prisma Migrate does not emit those `COMMENT ON COLUMN` statements itself — add them by hand in the migration when you want DB-level visibility. A plain `//` reaches neither.
- **The gate is diff-scoped.** The `pr-gates` workflow fails only on columns a PR *adds or modifies* without a `///` comment; pre-existing uncommented columns are grandfathered. Enforce the new; don't boil the ocean.

## Tenant scoping
- **A `where` filter scopes only the rows it sits on — it does not reach into a join.** In a nested `include` / nested `select` / joined query, the outer tenant filter does **not** propagate to the nested relation. Any nested relation that can span tenants (a user's teams, a record's attachments, a comment's author) needs its **own** org/tenant filter, even when the top-level query is already scoped to the caller's org.
- **These leaks are silent — right shape, wrong rows.** The response keeps its expected structure; only the contents are wrong (they carry another tenant's data). A fixture with a single org passes every assertion, so the bug ships green. When you add or touch a nested relation on a multi-tenant model, ask "can this relation cross the tenant boundary?" — scope it if so, and prove it with a test that seeds a *second* org and asserts none of its rows appear.

## Mistakes
<!-- The codify-the-findings flywheel. When a review finding or debugging
     session reveals a repo-specific gotcha, append one bullet here:
     **[category]**: what bites, and the fix. Agents read this every session —
     an entry here stops the mistake from being GENERATED again. -->
