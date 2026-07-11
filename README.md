# InformUp Engineering Harness

Guardrails for **agent-led engineering**: novice engineers working with coding
agents submit small, complete PRs; a senior engineer (assisted by agents)
reviews for what machines can't own. Standard tools enforce everything
mechanical; the repo itself carries the standards so agents *generate*
conforming work instead of having it bounced.

Extracted from the live pilot on [INFORMUP/TaskFlow](https://github.com/INFORMUP/TaskFlow).
Design rationale: [docs/PROPOSAL.md](docs/PROPOSAL.md) ·
[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) (the TaskFlow-grounded spec).

## What you get (Phases 0–1: foundations + mechanical gates)

| Guarantee | Mechanism | File |
|---|---|---|
| Atomic PRs (≤500 lines, ≤5 files) | size gate | `.github/workflows/pr-gates.yml` |
| PR describes what/why + real verification evidence | template check | `pr-gates.yml` + `PULL_REQUEST_TEMPLATE.md` |
| New suppressions carry `-- reason:`; `.only` never merges | suppression gate (anti-cheat for every other gate) | `pr-gates.yml` |
| Coverage never silently decreases | self-seeding ratchet vs. pinned floors | `.github/scripts/coverage-ratchet.sh` + `coverage-baseline.json` |
| Conventional-Commit history | PR-title lint + squash-only merges | `commitlint.yml` + ruleset |
| Docs have owners and lifecycles | taxonomy | `docs/README.md` |
| Style is human-governed, agent-cited | house style guide (agents never edit) | `docs/style.md` |
| Duplication is intentional, never accidental | generated reuse inventory (drift-checked) + PR `## Reuse` section + reuse gate on new exports + advisory `jscpd` | `scripts/generate-inventory.mjs` + `pr-gates.yml` + `duplication.yml` |
| Agents generate conforming work | Definition of Done + Mistakes flywheel | `CLAUDE-sections.md` → target `CLAUDE.md` |
| All of the above is **binding**, not advisory | **two** repository rulesets: `main-integrity` (required checks, linear history, no force-push — **no bypass actors, admins included**) + `main-review` (squash-only, thread resolution, 1 CODEOWNER review — PR-mode admin waiver for the sole senior's own PRs) | `rulesets/` + `scripts/install-ruleset.sh` |

Overrides are deliberate and visible: `size-override` / `coverage-override`
labels (senior judgment, audit-trailed), repo-admin ruleset bypass for
emergencies. A justified suppression needs no override — its justification
*is* the override.

## Install

```bash
# 1. Copy the template into your repo (never overwrites; reports conflicts)
scripts/install.sh ~/src/your-repo

# 2. Do the printed manual follow-ups (CODEOWNERS, CLAUDE.md splice,
#    test-workflow wiring, hooks, labels — per-stack by design)

# 3. Make it binding (requires GitHub Team for private repos)
scripts/install-ruleset.sh ORG/your-repo backend,frontend,gates,lint-pr-title
```

**CODEOWNERS = exactly the seniors (usually one).** GitHub doesn't count
self-approval, so the sole senior's own PRs will always read
`BLOCKED/REVIEW_REQUIRED` — that's expected. Their merge path is
`gh pr merge --admin --squash` after green checks: the ruleset split makes
`--admin` waive **only** the review rule (`main-integrity` has no bypass
actors, so red CI stays unmergeable). Do **not** add a junior as a second
owner to "fix" the deadlock — that lets them approve every other junior's
work. Learned the hard way on the pilot (TaskFlow #318 → reverted in #319).

## The contract your repo provides

The template is stack-agnostic; these five integration points are yours:

1. **A test workflow** that runs per-package tests with a `json-summary`
   coverage reporter and then calls `coverage-ratchet.sh <package-key>` from
   the package dir (keys = `coverage-baseline.json` keys). Floors ship `null`
   (report-only); pin them from your first CI run. Reference implementation:
   TaskFlow's `test.yml`. Tip from the pilot: coverage instrumentation slows
   suites — TaskFlow's backend needed `--testTimeout=15000` on the coverage
   invocation only.
2. **Check names** for the ruleset — your CI job names as they appear on PRs.
3. **Suppression vocabulary** — `pr-gates.yml` ships JS/TS tokens; extend
   `SUPPRESS_RE` for your stack (Python: `noqa`, `type: ignore`,
   `pragma: no cover`, `pytest.mark.skip`).
4. **Pre-commit hook contents** — `.githooks/pre-commit` is a skeleton; keep
   it to seconds. Hooks are the fast path, CI is the guarantee.
5. **Reuse surface** — set `SURFACE_DIRS` in `scripts/generate-inventory.mjs`
   and the matching `REUSE_PATHS` env in `pr-gates.yml`'s Reuse gate (keep them
   in lockstep), run the generator once to seed `docs/inventory.md`, and adjust
   `duplication.yml`'s scan paths. The inventory drift-check self-activates
   when the script exists.
6. **Lint-level suppression rules** (TS stacks) — in each `eslint.config.js`:

   ```js
   {
     linterOptions: { reportUnusedDisableDirectives: "error" },
     rules: {
       "@typescript-eslint/ban-ts-comment": ["error", {
         "ts-expect-error": { descriptionFormat: "^ -- reason: .+$" },
         "ts-ignore": true,
         "ts-nocheck": true,
         minimumDescriptionLength: 12,
       }],
       // Advisory complexity signal (pilot-validated): warn-level, threshold at
       // SonarJS's default; measure your p95 first so it fires only on outliers.
       "sonarjs/cognitive-complexity": ["warn", 15],
     },
   }
   // With Prettier, end the config with eslint-config-prettier (must stay
   // LAST) so ESLint stops fighting the formatter.
   ```

## Operating principles (the short version)

- **Codify standards where agents read them.** Every recurring review finding
  becomes a rule — in `CLAUDE.md` (agent behavior), `docs/style.md` (style,
  human-led), or a lint rule. Mistakes stop being *generated*, not just caught.
- **Standard tools enforce what's mechanical; agents cover judgment.** Nothing
  in this template requires an AI to run; the agent layers (first-pass review,
  doc drift, audits) sit on top.
- **Docs ride in the same PR as the code.** The taxonomy names an owner and a
  lifecycle for every doc type.
- **Suppressions are the cheat vector — gate them.** Including config-level
  cheats: coverage excludes and lint-config edits belong in CODEOWNERS.

## Roadmap (from docs/IMPLEMENTATION.md)

- **Phase 2 — agents in the loop:** checked-in `.claude/settings.json` + hooks
  (post-edit lint, destructive-command impact statements), `write-tests` skill,
  automated first-pass PR review, ADR backfill.
- **Phase 3 — plan gate & docs system:** plan-required paths, plans-as-PRs with
  archive lifecycle, code↔doc map, weekly drift check, metrics.
- **Phase 4 — audits:** monthly scanner+synthesis audit, quarterly deep audit;
  findings become tracked tasks.

Pilot learnings worth keeping:

- The suppression gate flagged its own PR on its first CI run (a config
  comment quoted a token) — proof it scans real diffs.
- Coverage floors were pinned from CI's own measurements, never aspirational
  targets.
- The governance split (`main-integrity`/`main-review`) came from real holes:
  a single ruleset with an always-on admin bypass let admins merge red builds
  and push straight to main, and a bare 1-approval rule let any two juniors
  merge each other's work.
- **Teach your agent commands the gates** (pilot PR "teach /implement the PR
  gates it keeps tripping"): every gate an agent trips repeatedly should be
  encoded into the command/skill that generates the work, not just enforced
  after the fact.
- The senior consolidating a deliberately-duplicated helper at merge time
  (task-links' access guard → shared `_guards.ts`) is the reuse loop working:
  declared duplication in, consolidation decision out.
- Prettier sweeps may need 2–3 whole-tree `--write` passes to converge; loop
  until `--check` is clean before committing, and record the sweep SHA in
  `.git-blame-ignore-revs`.
- A required check must run on **every** PR: a workflow skipped by a path
  filter never creates its check run, and with no bypass actors nothing can
  unstick the wait (see `quality.yml.example`'s `format` job).
