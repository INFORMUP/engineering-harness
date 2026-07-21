# Self-tests for the template gate scripts

This directory holds self-tests for two of the gate scripts shipped under
`template/.github/scripts/`:

- `schema-comment-check.mjs` — the diff-scoped Prisma column-comment gate.
- `coverage-ratchet.sh` — the per-package coverage floor/ratchet check.

## Why these live at the repo root, not under `template/`

`scripts/install.sh` copies everything under `template/` verbatim into
consumer repos. Anything under `template/` ships downstream. These tests (and
the CI workflow that runs them) test the harness's own scripts, so they stay
at the repo root — outside `template/` — and are never installed into a
consumer repo.

## Running locally

```bash
node --test tests/schema-comment-check.test.mjs
bash tests/coverage-ratchet.test.sh
```

Both are hermetic: each test case builds its own temporary git repo (for the
schema-comment gate) or temporary directory with a fake coverage summary and
baseline (for the coverage ratchet), so nothing depends on this repo's own
history or state.

## CI

`.github/workflows/self-test.yml` runs both commands above on every push to
`main` and on every pull request.
