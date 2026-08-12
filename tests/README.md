# Self-tests for the template gate scripts

This directory holds self-tests for the gate scripts shipped to consumer
repos, whether from `template/.github/scripts/` or from an opt-in module's
`modules/*/.github/scripts/`:

- `schema-comment-check.mjs` — the diff-scoped Prisma column-comment gate.
- `claude-sections-check.sh` — the gate asserting the shared CLAUDE.md sections
  were spliced into the consumer repo.
- `coverage-ratchet.sh` — the per-package coverage floor/ratchet check.
- `taskflow-link.mjs` — the TaskFlow module's task gate and PR linker.

## The one rule: every gate script has a matching self-test

Each shipped script **must** have a self-test named
`tests/<script-basename>.test.<ext>`:

| Script                                       | Self-test                              |
| -------------------------------------------- | -------------------------------------- |
| `template/.github/scripts/coverage-ratchet.sh`     | `tests/coverage-ratchet.test.sh`       |
| `template/.github/scripts/schema-comment-check.mjs`| `tests/schema-comment-check.test.mjs`  |
| `template/.github/scripts/claude-sections-check.sh` | `tests/claude-sections-check.test.sh`  |
| `modules/taskflow/.github/scripts/taskflow-link.mjs`| `tests/taskflow-link.test.mjs`         |

The test keeps its own extension (`.mjs` for a node test, `.sh` for a bash
test), independent of the script's. `tests/check-coverage.sh` enforces this
mapping in CI: a script with no matching test **fails the build**.

This is deliberate. The workflow discovers and runs whatever tests exist by
glob, so without the manifest gate a new gate script added with no test would
leave CI green — and then fan out to every consumer on the next `install.sh`
sync, untested. The gate makes the guarantee "every shipped script is tested,"
not "every test we remembered to write runs." So: **add a script, add its
test** — there is no opt-out. (If a genuinely non-runnable helper file ever
needs to live in `scripts/`, that is the moment to add an escape hatch to
`check-coverage.sh`, not before.)

## Why these live at the repo root, not under `template/`

`scripts/install.sh` copies everything under `template/` verbatim into
consumer repos, and `scripts/install-module.sh` does the same for a module.
Anything under `template/` or `modules/` ships downstream. These tests (and
the CI workflow that runs them) test the harness's own scripts, so they stay
at the repo root — outside `template/` — and are never installed into a
consumer repo.

## Running locally

```bash
bash tests/check-coverage.sh          # every script has a test?
node --test tests/*.test.mjs          # all node self-tests
bash tests/coverage-ratchet.test.sh   # (or any single bash self-test)
```

The self-tests are hermetic: each case builds its own temporary git repo (for
the schema-comment gate) or temporary directory with a fake coverage summary
and baseline (for the coverage ratchet), so nothing depends on this repo's own
history or state.

## CI

`.github/workflows/self-test.yml` runs, on every push to `main` and every pull
request: the coverage-manifest gate (`check-coverage.sh`), then all node
self-tests (`tests/*.test.mjs`, discovered by glob), then every bash
self-test (`tests/*.test.sh`).
