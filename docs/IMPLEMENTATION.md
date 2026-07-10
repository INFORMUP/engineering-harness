# Agent-Led Engineering Harness — Technical Implementation Spec

**Status:** Rev 2 — team feedback synthesized · July 7, 2026
**Pilot:** `INFORMUP/TaskFlow` (Fastify + Prisma + TypeBox backend · Vue 3 + Vite frontend · Vitest both sides · Playwright e2e)
**Companion doc:** PROPOSAL.md (approved design principles)

**Changed in Rev 2:** house style guide (human-edited only) inheriting from Google's; suppression-directive policy (justified + reviewer-approved `#ignore`s); bug-fix regression-test protocol; plan archive lifecycle; documentation system expanded into a full taxonomy (§3.8); recurring codebase audits (§3.11); subscription-first cost model (§3.10); Decision 5 resolved.

---

## 1. Gap analysis — what TaskFlow already has

The harness extends TaskFlow's existing system; it does not replace it.

| Area | In place today | Gap the harness fills |
|---|---|---|
| CI | `test.yml`: backend Vitest vs. real Postgres (migrations + seed), frontend Vitest, Playwright e2e, draft-aware, concurrency-cancel | No lint, typecheck, or build step in CI; no coverage; two known-broken e2e specs (issue #20) prevent strict gating |
| Commit convention | `commitlint.yml` validates PR titles (Conventional Commits) | Local commit-msg check; squash-only merge so the validated title becomes the commit |
| Git hooks | `.githooks/pre-commit` (tsc + vue-tsc), via `core.hooksPath` | No lint/format/tests at commit; hook install is manual and unverified |
| Migration safety | `migration-sync-gate.yml`, `enforce-staging-gate.yml` | Plan gate for schema/cross-module changes (upstream of migration mechanics) |
| Agent config | Root `CLAUDE.md` + `OVERVIEW.md`; rich `.claude/commands/` task spine (`/design` → `/implement` → `/validate` → `/address-review`, `/resolve-bug`) | No `.claude/settings.json` (hooks, default model); no test-writing or audit skills; plan-first must **fuse with the existing shaping stage**, not sit beside it |
| Docs | `docs/db.md`, `api.md`, `permissions.md`, `taskflows.md`, `tech-stack.md`, … | No taxonomy/ownership rules, no house style guide, no ADRs, no `docs/plans/`, no code↔doc map, no drift check, no audit trail |
| Governance | — | No PR template, no CODEOWNERS, no branch protection (**blocked: free-plan private repo — see §6, Decision 1**), no Claude review, no size gate, no suppression policy |

## 2. Target repo layout

```
TaskFlow/
├── CLAUDE.md                        EXTEND: + Definition of Done, style pointer, protected paths
├── .claude/
│   ├── settings.json                NEW: default model, hooks wiring
│   ├── hooks/
│   │   ├── lint-file.sh             NEW: post-edit lint feedback loop
│   │   └── guard-destructive.sh     NEW: impact-check on dangerous commands
│   ├── skills/
│   │   ├── write-tests/SKILL.md     NEW: test-writing skill
│   │   └── audit/SKILL.md           NEW: codebase-audit skill (§3.11)
│   └── commands/
│       ├── design.md                EXTEND: emit plan PRs for plan-required work
│       └── resolve-bug.md           EXTEND: regression-test + gap-audit protocol (§3.7)
├── .githooks/
│   ├── pre-commit                   EXTEND: + lint/format staged, related tests
│   └── commit-msg                   NEW: commitlint locally
├── .github/
│   ├── PULL_REQUEST_TEMPLATE.md     NEW
│   ├── CODEOWNERS                   NEW (binding only after plan upgrade)
│   ├── doc-map.yml                  NEW: code globs → doc files
│   ├── plan-required.yml            NEW: globs that trigger the plan gate
│   ├── coverage-baseline.json       NEW: per-package ratchet floor
│   └── workflows/
│       ├── test.yml                 KEEP (quarantine issue-#20 e2e specs)
│       ├── quality.yml              NEW: lint, typecheck, build, coverage ratchet
│       ├── pr-gates.yml             NEW: size gate, plan gate, template check, suppression scan
│       ├── claude-review.yml        NEW: automated first-pass review
│       ├── doc-drift.yml            NEW: weekly staleness check
│       ├── audit.yml                NEW: monthly codebase audit (§3.11)
│       └── metrics.yml              NEW: monthly metrics issue
├── docs/
│   ├── README.md                    NEW: documentation taxonomy + ownership index (§3.8.1)
│   ├── style.md                     NEW: house style guide — HUMAN-EDITED ONLY (§3.1)
│   ├── architecture.md              NEW: one-page system map (distilled from OVERVIEW.md)
│   ├── adr/                         NEW: 0000-template + backfilled ADRs 0001–0005
│   ├── plans/                       NEW: active plan documents (one per plan PR)
│   │   └── archive/                 NEW: implemented plans, retained for reference
│   └── audits/                      NEW: dated audit reports (append-only)
└── scripts/setup-dev.sh             NEW: hooksPath, deps, env sanity
```

## 3. Component specs

### 3.1 CLAUDE.md — Definition of Done + style (EXTEND)

**Definition of Done** (agents treat as a checklist; `claude-review` re-verifies):

> Every implementation PR: (1) lint + typecheck clean; (2) tests for changed behavior including edge cases per the `write-tests` skill, proven by revert-the-fix; (3) bug fixes include a regression test that failed before the fix (§3.7); (4) docs updated per `doc-map.yml`; (5) Conventional-Commit title; (6) ≤ 500 changed lines and ≤ 5 files (excluding lockfiles, `prisma/migrations/`, `docs/`); (7) merged plan linked if any protected path is touched; (8) **no new suppression directive without an inline justification** (§3.6).

**Style — two-level inheritance, human-owned.** `docs/style.md` is the **house style guide**; it declares the Google TypeScript Style Guide as its parent and records only house deviations and additions. Precedence: house rule > Google rule > linter default. **Agents never edit `docs/style.md`** — updates are human-led only. Enforced three ways: a `CLAUDE.md` prohibition ("propose style changes in an issue; never edit docs/style.md"), a CODEOWNERS entry, and a `pr-gates` check that fails any PR touching `docs/style.md` unless a human authored the change (senior-applied `style-update` label). Mechanical rules from both levels are encoded in the ESLint flat configs + Prettier (§3.4); judgment aspects (naming, comment quality, API design) are checked by `claude-review` against the house guide first, Google's second.

### 3.2 `.claude/settings.json` + hooks (NEW)

```json
{
  "model": "sonnet",
  "hooks": {
    "PostToolUse": [{ "matcher": "Edit|Write",
      "hooks": [{ "type": "command", "command": ".claude/hooks/lint-file.sh" }] }],
    "PreToolUse": [{ "matcher": "Bash",
      "hooks": [{ "type": "command", "command": ".claude/hooks/guard-destructive.sh" }] }]
  }
}
```

- **`lint-file.sh`** — runs `eslint --fix` on the just-edited file in the right package; remaining errors are fed back so the agent self-corrects immediately. Typecheck stays at commit time (project-wide `tsc` per edit is too slow).
- **`guard-destructive.sh`** — matches `git push --force`, `prisma migrate reset`, `prisma db push`, `rm -rf`, `DROP`/`TRUNCATE`. Per team feedback it does **not** hard-block; it returns `"permissionDecision": "ask"` with a reason instructing the agent to first consult `docs/db.md` / `docs/architecture.md` and state the blast radius — so the human approves with an impact statement in front of them.

### 3.3 `write-tests` skill (NEW)

Encodes the testing pyramid **mapped to TaskFlow's real patterns**:

- **Unit** — pure logic (e.g. `transition.service.ts`, permission matrix); most tests live here.
- **Integration** — Fastify routes against the real dev DB using the existing `mintTestToken()` helper; respects `fileParallelism: false` (shared Postgres).
- **Component** — `@vue/test-utils` + happy-dom.
- **E2E** — Playwright smoke paths only; new e2e specs need justification.

Required edge-case checklist: boundaries, empty/null, **authz-denied paths** (one per permission-matrix rule touched), error-handler paths, invalid state transitions. Mandatory **prove-the-test** step: temporarily revert the implementation, confirm the new test fails, restore. For bug fixes, the skill defers to the regression protocol in §3.7.

### 3.4 Commit-time hooks (EXTEND `.githooks/`)

Keep the existing `core.hooksPath` approach (no husky migration). `pre-commit` becomes: Prettier + `eslint --fix` on staged files → `tsc --noEmit` + `vue-tsc --noEmit` (as today) → `vitest related --run` on staged source files. New `commit-msg` runs commitlint with the same ruleset as CI. `scripts/setup-dev.sh` sets `core.hooksPath`, installs both packages, verifies Postgres — and `CLAUDE.md` instructs agents to run it at session start if hooks are missing. Hooks are the fast path; CI remains the guarantee.

One-time Prettier adoption commit with `.git-blame-ignore-revs` (Decision 2).

### 3.5 `quality.yml` — CI extensions (NEW)

Jobs per package: `lint` (`eslint src`), `typecheck`, `build` (`tsc` / `vue-tsc -b && vite build`), and `coverage`:

```
vitest run --coverage  →  compare lines.pct against .github/coverage-baseline.json
fail if new < baseline − 0.1;  if new > baseline, remind PR to bump the baseline file
```

Raising the baseline is a normal reviewed diff; lowering it requires the `coverage-override` label (senior-applied, verified by actor check). Baseline starts from **measured current coverage** (Decision 5 — approved). Prerequisite: quarantine the two issue-#20 e2e specs (`test.fixme`, with justification comments per §3.6) so all checks can eventually be strict.

### 3.6 `pr-gates.yml` — atomicity, plan, template, suppressions (NEW)

- **Size gate** *(mechanics approved in review)*: `git diff --numstat base...head` minus exclusions (`package-lock.json`, `prisma/migrations/**`, `docs/**`, `*.snap`) → fail if changed lines > 500 **or** files > 5. Override: `size-override` label; the workflow verifies the label was applied by an allowed senior.
- **Plan gate:** if any changed file matches `plan-required.yml` — proposed initial set: `backend/prisma/schema.prisma`, `backend/src/plugins/**` (auth, error handling), `**/permission.service.ts`, `frontend/src/router/**` — the PR body must contain `Plan: #NN`, and the workflow verifies via API that PR #NN is **merged** and touches `docs/plans/**`. This mechanically enforces "work does not continue until the plan PR is approved."
- **Template check:** required sections (What/Why, Verification evidence, Docs touched) are present and non-empty.
- **Suppression scan** *(new, per team feedback)* — anti-cheat for every gate above. Suppression directives are how an agent (or human) games the rules: `eslint-disable*`, `@ts-ignore` / `@ts-expect-error`, `prettier-ignore`, `test.skip/.todo/.fixme`, `describe.skip`, `/* istanbul ignore */`, `/* v8 ignore */`. Policy:
  1. **Every new suppression requires an inline justification** in a fixed format: `-- reason: <why this is safe/necessary> (<issue-ref if temporary>)`. Encoded mechanically where the toolchain supports it: `@eslint-community/eslint-plugin-eslint-comments` `require-description`, `@typescript-eslint/ban-ts-comment` with `allow-with-description` + minimum length, `reportUnusedDisableDirectives: error` (unused suppressions are also failures). The remainder (`test.skip`, coverage-ignore, `prettier-ignore`) is caught by a diff-scoped grep in `pr-gates.yml`: any new suppression token in added lines without a `-- reason:` on the same or preceding line fails the check.
  2. **The reviewing agent must approve each justification.** `claude-review` (§3.7) receives the scan output and renders an explicit verdict per suppression — reasonable, or request-changes with the rule-compliant alternative. Weak justifications ("linter is wrong", "temporary" with no issue ref) are named in the review summary for the senior.
  3. **Config-level cheats are gated too:** `eslint.config.js`, `vitest.config.*` (coverage excludes), `tsconfig*.json`, and `.github/coverage-baseline.json` are CODEOWNERS-listed (§3.9) and called out by name in the `claude-review` prompt — excluding a file from coverage is equivalent to suppressing every assertion in it.

### 3.7 `claude-review.yml` — automated first-pass review (NEW)

`anthropics/claude-code-action@v1` on non-draft PRs, Sonnet, concurrency-cancelled. The review prompt is a contract: check correctness; conventions per `CLAUDE.md`; house style guide (then Google) judgment calls; DoD — tests cover changed behavior incl. the §3.3 edge-case checklist; docs updated where `doc-map.yml` says they should be; plan linkage consistent; every new suppression justified (§3.6). Posts inline comments plus a summary verdict the senior reads first. **Advisory for pilot weeks 1–2, then a required check** (Decision 4).

**Bug-fix protocol** *(new, per team feedback)* — when the PR is `fix:`-typed or linked to a BUG task, the review applies a stricter standard:

1. **Regression test required** — a test that reproduces the reported failure and demonstrably failed before the fix (red→green evidence pasted in the PR's Verification section; the revert-the-fix step from §3.3 produces it naturally).
2. **Gap audit required** — the bug is evidence that existing tests and validation logic missed a case. The review examines the tests and validation covering the buggy path and asks: *what allowed this through?* Sibling gaps (same class of error, adjacent inputs, same permission rule elsewhere) must be either fixed in the PR or filed as follow-up BUG/IMP tasks — silently patching the single symptom is a request-changes.
3. The existing `/resolve-bug` command is extended to run this same protocol at authoring time, so contributors arrive at review already conforming.

Auth: subscription-first per §3.10 (`CLAUDE_CODE_OAUTH_TOKEN` secret; API key as fallback).

### 3.8 Documentation system (EXPANDED)

The documentation set is a typed system with explicit ownership and lifecycles, not a folder of markdown. `docs/README.md` carries this taxonomy in-repo so both humans and agents resolve "where does this get written down, and who approves it?" without asking.

#### 3.8.1 Taxonomy — every doc type, its owner, and its lifecycle

| Doc | Purpose | Drafted by | Approved by | Updated when | Lifecycle |
|---|---|---|---|---|---|
| `CLAUDE.md` | Agent operating contract: conventions, DoD, commands, protected paths | Agents may propose | Senior | A review finding recurs → codify it | Living |
| `OVERVIEW.md` | Product + architecture orientation for humans and agents | Agent | Senior | Architecture materially changes | Living |
| `docs/architecture.md` | One-page system map: components, boundaries, data flow; the doc `guard-destructive.sh` and ADRs point into | Agent (distilled from OVERVIEW + tech-stack) | Senior | An accepted ADR changes structure | Living |
| `docs/style.md` | House style guide, parent = Google TS Style Guide; deviations/additions only | **Humans only** | Senior | Human-led decision | Living, agent-edit prohibited (§3.1) |
| Domain docs (`db.md`, `api.md`, `permissions.md`, `taskflows.md`, …) | Per-domain reference: current truth about schema, endpoints, authz matrix, flows | Contributor's agent, **in the same PR as the code change** | Senior via PR review | `doc-map.yml` coupling fires | Living |
| `docs/adr/NNNN-*.md` | Rationale for one major decision | Contributor's agent | Senior (CODEOWNERS) | New dependency, schema change, cross-module design, auth/permission change | **Immutable once accepted** — never edited, only superseded |
| `docs/plans/*.md` | Pre-implementation contract for plan-required work | `/design` command | Senior (plan-PR merge = approval) | Plan-required paths touched | draft → approved → implemented → **archived** |
| `docs/audits/YYYY-MM*.md` | Point-in-time audit findings + disposition | Audit agent (§3.11) | Senior triage | Scheduled cadence | Append-only |
| `docs/README.md` | This taxonomy + ownership index | — | Senior | Taxonomy changes | Living |

Two cross-cutting rules: **(a)** docs carry lightweight frontmatter (`owner`, `last-verified: <date>`); the weekly drift job stamps `last-verified` on docs it checked clean, so staleness is visible at a glance and the drift job never re-litigates fresh docs. **(b)** Doc updates ride in the same PR as the code they describe — a separate "docs catch-up PR" is the failure mode the doc-map exists to prevent.

#### 3.8.2 ADRs — format and immutability

MADR-lite template (`docs/adr/0000-template.md`): **Status** (Proposed / Accepted / Superseded-by-NNNN) · **Date** · **Context** (forces at play) · **Decision** · **Options considered** (each with why it lost) · **Consequences** (positive *and* negative) · **Links** (TaskFlow task, plan PR, implementation PR). An ADR is Proposed while its PR is open and Accepted on merge. Accepted ADRs are never edited: a change of course is a *new* ADR whose merge also flips the old one's Status line to `Superseded-by-NNNN` — that status flip is the single permitted edit. **Seed content:** the five "Key Architecture Decisions" already listed in CLAUDE.md become ADR-0001…0005 (Fastify plugin encapsulation, static permission matrix, pure transition validation, JWT + `mintTestToken`, sequential test execution) — day-one examples of the format, with CLAUDE.md then linking to them instead of restating them.

#### 3.8.3 Plans — fused with the existing spine, with an archive lifecycle

`/design` (shaping stage) already freezes an acceptance-criteria contract as a task comment. Extension: when the task touches plan-required paths, `/design` also commits the contract as `docs/plans/<DISPLAY-ID>-slug.md` and opens a `plan`-labeled PR. Senior approval = merge; `/implement` refuses to start on plan-required work without a merged plan (checked in the command, enforced again by §3.6).

Plan template fields: **Task** (display ID + link) · **Problem / goal** · **Acceptance criteria** (the frozen contract) · **Approach** · **Schema / API impact** · **Test plan** (per §3.3 pyramid) · **Rollback** · **Out of scope**.

**Archive step** *(new, per team feedback)*: when an implementation PR whose body contains `Plan: #NN` merges, a post-merge job moves the plan file to `docs/plans/archive/`, stamping frontmatter `status: implemented`, `implemented-by: #<PR>`. (Bot-commits directly during the pilot — there's no branch protection to bypass; switches to an auto-PR after the plan upgrade.) `docs/plans/` therefore always shows exactly the work that is approved-but-not-landed — a free WIP dashboard — while the archive preserves every contract for future reference, and ADRs cite archived plans rather than duplicating them. The weekly drift job flags plans sitting active > 30 days with no linked implementation.

#### 3.8.4 `doc-map.yml` — deterministic code↔doc coupling

Natural fit for TaskFlow's per-domain docs. Proposed initial map:

```yaml
backend/prisma/**:                 [docs/db.md]
backend/src/routes/**:             [docs/api.md]
"**/permission.service.ts":        [docs/permissions.md, docs/users.md]
"**/transition.service.ts":        [docs/taskflows.md]
backend/src/plugins/**:            [docs/architecture.md]
frontend/src/router/**:            [docs/taskflows.md]
```

A `pr-gates` step warns when matched code changes lack a change to the mapped doc; `claude-review` judges whether the doc change is actually *sufficient* (the warn is deterministic, sufficiency is judgment). The map itself is senior-owned via CODEOWNERS — deleting a mapping is a documentation decision, not a convenience.

#### 3.8.5 `doc-drift.yml` — weekly staleness check

Weekly cron. Inputs: the week's merged PR diffs, `doc-map.yml`, and each doc's `last-verified` frontmatter. Procedure: map merged changes → affected docs → read doc against the new reality → verdict per doc. Outputs: one open `doc-drift:<doc>` issue per stale doc (updated in place, never duplicated; specific about *which sections* drifted), and a bot commit stamping `last-verified` on clean docs. Drift issues are filed into the TaskFlow spine as IMP tasks during weekly triage, so doc debt flows through the same pipeline as code work.

### 3.9 Governance: merge strategy, CODEOWNERS, branch protection

- **Squash-only merges** (repo setting, available today): currently all three methods are enabled; squash-only makes the commitlint-validated PR title the mainline commit message and keeps history atomic-PR-shaped.
- **CODEOWNERS:** `* @<senior>`, with explicit entries for `/docs/adr/`, `/docs/plans/`, `/docs/style.md`, `/docs/README.md`, `/CLAUDE.md`, `/.claude/`, `/.github/`, `backend/prisma/schema.prisma`, and the gate-relevant configs (`**/eslint.config.js`, `**/vitest.config.*`, `**/tsconfig*.json`) per §3.6.3.
- **Constraint found during this design:** the repo is **private on a free GitHub plan** — branch protection, rulesets, required checks, and CODEOWNERS enforcement are all unavailable (API returns 403; this is why `enforce-staging-gate.yml` exists as a CI-level workaround). Until resolved, every gate above runs and reports but a merge can technically ignore it. **Recommendation: upgrade the org to GitHub Team (~$4/user/mo)** — it converts the entire harness from advisory to binding and is the single highest-leverage line item in the budget (Decision 1).

### 3.10 Cost controls & metrics — subscription-first (REVISED)

Per team direction, the harness leans on contributors' **Claude monthly subscriptions** wherever possible; metered API spend is the exception, not the default.

- **Local development (the bulk of usage): $0 marginal.** Contributors run Claude Code under their own Pro/Max subscription. The checked-in `"model": "sonnet"` default stretches subscription session limits; contributors escalate to Opus deliberately (planning, hard debugging), not by default.
- **CI first-pass review + scheduled jobs:** `claude-code-action` accepts a subscription OAuth token (`claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` secret) as an alternative to an API key. Pilot runs on the senior's subscription token. Two caveats, stated so nobody is surprised: usage counts against that individual's rate limits (a busy PR day and the senior's local sessions share one budget), and attribution is per-account, not per-workflow. If CI volume starts crowding out the senior's own usage, fall back to a **dedicated API key with a monthly cap** — that's the tripwire, revisited in the monthly metrics review (Decision 6).
- **Deep review:** `/code-review ultra` is senior-triggered on `risky`/`size-override` PRs, billed to their seat.
- **Scheduled jobs are cheap by construction:** drift (§3.8.5), audit (§3.11), and metrics run weekly/monthly on Sonnet, with deterministic scanners doing the heavy lifting before Claude synthesizes.
- **`metrics.yml`** (monthly cron) opens an issue: merged-PR count, median PR size, review rounds per PR, revert count (`^Revert`), coverage-baseline trend, suppression count trend (§3.6), active-plan age; spend/limit-pressure figures from the Console and seat analytics pasted in (automatable later).

### 3.11 Recurring codebase audits (NEW — answers "how might we facilitate audits?")

PR review sees the codebase one diff at a time; audits see what no diff shows — accumulated drift, debt, and hotspots. Two cadences, one pipeline:

**Monthly automated audit** (`audit.yml`, scheduled): deterministic scanners run first and Claude synthesizes — judgment sits on top of cheap mechanical truth, same principle as the rest of the harness.

| Dimension | Deterministic input | Claude's judgment layer |
|---|---|---|
| Architecture conformance | import graph, dependency list vs. ADR index | code that violates `architecture.md` boundaries; dependencies with no ADR |
| Security & authz | `npm audit`, secret scan, route list | routes vs. permission matrix — endpoints missing authz-denied tests |
| Test health | skipped-test inventory, slowest/flakiest tests, coverage JSON | coverage cold spots ranked by churn (untested *and* frequently changed = risk) |
| Suppression debt | full `#ignore` inventory (§3.6 scan, repo-wide) | expired justifications; suppressions whose issue refs are closed |
| Dead code & deps | `knip`/`depcheck`, unused exports | safe-to-delete vs. load-bearing-but-unimported |
| Complexity hotspots | churn × file size ranking | refactor candidates worth an IMP task, with rationale |
| Docs accuracy | drift-job history, `last-verified` ages | deep pass beyond the weekly diff-scoped check |

Output: `docs/audits/YYYY-MM.md` (committed via PR, senior approves) — findings ranked by severity, each with a disposition column. **Every accepted finding becomes a TaskFlow task** (BUG or IMP flow) and flows through the normal harness; an audit that doesn't end in tasks is a report nobody read. The report opens with a delta-vs-last-audit section so trends (suppression count, cold-spot count, dep vulnerabilities) are one glance.

**Quarterly deep audit** (senior-driven, on their Max subscription — consistent with §3.10): the senior runs the `audit` skill locally with full context plus `/code-review ultra` over the highest-risk areas the monthly reports flagged, and reviews the quarter's ADRs against what actually got built. Deliverable: same report format, plus proposed CLAUDE.md/lint-rule changes — the codify-the-findings flywheel applied to the whole codebase instead of one PR.

`.claude/skills/audit/SKILL.md` encodes the dimension checklist, scanner commands, report format, and task-filing conventions, so monthly automation, quarterly deep-dives, and any ad-hoc "audit X" request all produce comparable, diffable reports.

## 4. Enforcement matrix

| Requirement | Mechanism | Binding? | Override |
|---|---|---|---|
| Atomic PRs (≤500 lines, ≤5 files) | `pr-gates.yml` size gate | Hard¹ | `size-override` label (senior) |
| Conventional commits | `commitlint.yml` (CI) + `commit-msg` hook + squash-only | Hard¹ | — |
| Lint / format / typecheck / build | pre-commit hook (fast path) + `quality.yml` (guarantee) | Hard¹ | — |
| Tests pass | `test.yml` (existing) | Hard¹ | — |
| Coverage never decreases | ratchet vs. `coverage-baseline.json` | Hard¹ | `coverage-override` label (senior) |
| **Suppressions justified & approved** | lint rules + diff scan (mechanical) + `claude-review` verdict per suppression + config files CODEOWNERS-gated | Hard¹ (format) / Soft (adequacy) | Senior judgment |
| Edge cases actually tested | `write-tests` skill (generation) + `claude-review` (verification) | Soft | Senior judgment |
| **Bug fixes carry regression test + gap audit** | `/resolve-bug` protocol + `claude-review` fix-typed standard | Soft (hard once review is required) | Senior judgment |
| Plan approved before risky code | `/implement` refusal + `pr-gates.yml` plan gate | Hard¹ | Edit `plan-required.yml` (senior-owned) |
| **Plans archived after landing** | post-merge archive job + drift-job aging check | Hard (automated) | — |
| ADR for major decisions | `claude-review` flags + senior review | Soft | Senior judgment |
| Docs updated with code | `doc-map.yml` warn + `claude-review` sufficiency check + weekly drift job | Soft | Senior judgment |
| House style (Google-inherited) | ESLint/Prettier (mechanical) + `claude-review` (judgment) | Mixed | Lint config change via PR (senior-owned) |
| **Style guide edited by humans only** | CLAUDE.md prohibition + CODEOWNERS + `style-update` label check | Hard¹ | Senior applies label |
| Destructive-command awareness | `guard-destructive.sh` → impact statement → human approves | Soft by design | Human approval is the mechanism |
| No direct pushes to main | Branch protection | **Blocked** | Requires GitHub Team (Decision 1) |

¹ "Hard" = CI fails. Truly binding only once required checks exist (Decision 1); until then, socially enforced red-means-stop.

## 5. Build order (each phase independently shippable)

- **Phase 0 — foundations (~½ day):** squash-only setting; PR template; CODEOWNERS; CLAUDE.md DoD + style-pointer sections; `docs/README.md` taxonomy; `docs/style.md` skeleton (human fills deviations); quarantine issue-#20 e2e specs (with §3.6 justifications); GitHub Team upgrade decision.
- **Phase 1 — mechanical gates (~1 day):** `quality.yml` (lint/typecheck/build); coverage baseline measured from current state + ratchet; `pr-gates.yml` (size + template + **suppression scan**, incl. the lint-level suppression rules); extend `.githooks/` + `setup-dev.sh`; one-time Prettier commit + `.git-blame-ignore-revs`.
- **Phase 2 — Claude in the loop (~1 day):** `.claude/settings.json` + both hooks; `write-tests` skill; `claude-review.yml` (advisory, subscription token, incl. suppression verdicts + **bug-fix protocol**); extend `/resolve-bug`; backfill ADRs 0001–0005; `docs/architecture.md`.
- **Phase 3 — plan gate, docs system & drift (~1 day):** `plan-required.yml` + plan gate; `/design` command extension (plan PRs); **plan archive job**; `doc-map.yml` + coupling warn; `doc-drift.yml` + `last-verified` stamping; `metrics.yml`; flip `claude-review` to required.
- **Phase 4 — audits (~½ day):** `audit` skill; `audit.yml` monthly; first baseline audit run → its findings seed the pilot backlog alongside the decomposed mega-PR features.
- **Pilot:** land the decomposed mega-PR features through the harness, one at a time. After each: any recurring review finding becomes a CLAUDE.md rule, lint rule, or skill update — that feedback loop *is* the pilot's deliverable.

## 6. Decisions

**Resolved in this rev:**
- ~~Coverage baseline~~ — **approved:** ratchet starts from measured current coverage.
- ~~Size-gate mechanics~~ — approved in review (comment was truncated mid-sentence — flag if that read is wrong).
- ~~Budget direction~~ — **subscription-first accepted** (§3.10); what remains is the CI-token sub-decision below.

**Open:**
1. **GitHub plan upgrade** (Team, ~$4/user/mo) to make gates binding — or accept advisory-only enforcement for the pilot?
2. **Prettier adoption** via one-time format commit with blame-ignore (recommended) — or lint-only, no formatter?
3. **Plan-required path list** — confirm/adjust the proposed initial set (§3.6).
4. **Claude-review timing** — advisory weeks 1–2 then required (recommended), or required from day one?
5. **CI auth source** — senior's subscription OAuth token (recommended for pilot; shares the senior's rate limits) with a capped API key as the documented fallback tripwire?
6. **Audit cadence** — monthly automated + quarterly deep (recommended, §3.11), and confirm audit findings are filed as TaskFlow BUG/IMP tasks?
