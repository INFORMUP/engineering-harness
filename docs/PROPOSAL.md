# Agent-Led Engineering Harness — Initial Design Proposal

**Status:** Draft for stakeholder feedback · July 6, 2026

## Goal

Enable novice engineers, working with coding agents in local environments, to submit **atomic, mature PRs** — small, linted, tested, and documented — reviewed by a senior engineer whose own agents handle the mechanical checks, so human attention goes to design and architecture. The repository itself carries the engineering standards and the rationale behind major decisions.

## Design principles

1. **Codify standards where agents read them.** Conventions, architecture, and the definition of done live in the repo (`CLAUDE.md`). Every recurring review finding becomes a written rule, so mistakes stop being *generated* rather than repeatedly caught.
2. **Standard tools enforce what's mechanical; Claude covers what requires judgment.** Linters, git hooks, and GitHub Actions gate formatting, tests, and PR size. Claude handles first-pass review, ADR drafting, and documentation drift.

## The harness, in four layers

### 1. Local development (contributor machines)
- **Checked-in agent config** — `CLAUDE.md` (conventions, architecture map, definition of done) plus shared Claude Code settings: auto-lint/typecheck after every edit, destructive commands blocked.
- **Git pre-commit hooks** (husky + lint-staged, or `pre-commit` for Python) — formatter, linter, typecheck, tests on changed files, Conventional Commits message lint. Nothing malformed ever reaches a PR.
- **Plan-first workflow** — non-trivial changes start as a short written plan the senior approves *before* code is written. Plans are cheap to correct; code is not.

### 2. PR pipeline (GitHub)
- **Branch protection** — no direct pushes to main; required CI checks and required review.
- **CI (GitHub Actions)** — lint, typecheck, full test suite, build, and a **coverage ratchet** (coverage may never decrease).
- **PR size gate** — CI fails PRs above ~400 changed lines (generated files excluded), mechanically enforcing atomicity.
- **Automated first-pass review** — Claude (via the official `claude-code-action`) reviews every PR for correctness, convention violations, and missing tests or docs before the senior looks.
- **PR template** — what/why, verification evidence (real test output), docs touched.

### 3. Documentation
- **Architecture docs + ADRs in-repo** — `docs/architecture.md` plus one Architecture Decision Record per major decision (new dependency, schema change, cross-module design) capturing context, options considered, and rationale. The contributor's agent drafts; the senior approves.
- **Docs in the definition of done** — the automated PR review flags code changes that touch documented behavior without a matching docs update.
- **Scheduled drift check** — a weekly Claude job compares recent merges against the docs and files issues for anything stale.

### 4. Review and cost control
- **Layered review** — CI gate → agent review → human review limited to design, data model, API surface, and security.
- **Model tiering** — contributors default to a mid-tier model (Sonnet); expensive deep review is reserved for large or risky PRs.
- **Monthly metrics** — spend per merged PR, revert rate, review iterations per PR, coverage trend.

## Rollout

Pilot on one repository with 2–3 contributors for ~4 weeks. Tune the rules from real review findings, then extract the harness into a template applied to other repos.

## Open questions for stakeholders

1. Which repo pilots this, and what stack? (Fixes the exact linter/test tooling.)
2. Is ~400 changed lines the right PR size limit?
3. Who approves plans and ADRs — a single senior, or rotating?
4. What monthly agent budget per contributor?
