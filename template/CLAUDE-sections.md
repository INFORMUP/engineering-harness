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
- **Session setup:** run `./install-pre-commit-hooks.sh` before your first commit in a session (idempotent). It activates the git hooks in `.githooks/`, so commits get the same formatting / type-check / reuse-inventory-sync gates CI enforces — caught locally instead of as a red build.
- Run the affected package's tests before committing. Hooks are the fast path; CI is the guarantee.
- No `--no-verify` and no force-push.

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
