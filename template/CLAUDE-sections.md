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
- Run the affected package's tests before committing.
- Git hooks live in `.githooks/`. After cloning, run `git config core.hooksPath .githooks` to activate them. Hooks are the fast path; CI is the guarantee.
- No `--no-verify` and no force-push.

## Mistakes
<!-- The codify-the-findings flywheel. When a review finding or debugging
     session reveals a repo-specific gotcha, append one bullet here:
     **[category]**: what bites, and the fix. Agents read this every session —
     an entry here stops the mistake from being GENERATED again. -->
