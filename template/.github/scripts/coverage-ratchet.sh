#!/usr/bin/env bash
# Coverage ratchet: fail if a package's line coverage drops below its pinned
# floor in .github/coverage-baseline.json. Invoke from your test workflow with
# the package key as $1 (must match a key in the baseline file), cwd = that
# package's directory, after running tests with a coverage reporter that
# writes coverage/coverage-summary.json (vitest/jest: json-summary).
#
# Semantics (keep in lockstep with the baseline file's _readme):
#   - baseline null  -> report-only: print the measured value so it can be
#                       pinned, and pass. This makes the ratchet self-seeding.
#   - measured < baseline - 0.1 -> FAIL (0.1pt tolerance absorbs float noise
#                       and provider jitter, not real regressions)
#   - measured > baseline + 0.1 -> pass, but nudge the PR to bump the floor
set -euo pipefail

PACKAGE="$1"
SUMMARY="coverage/coverage-summary.json"
BASELINE="../.github/coverage-baseline.json"

if [[ ! -f "$SUMMARY" ]]; then
  echo "FAIL: $SUMMARY not found — did the test run execute with --coverage?"
  exit 1
fi

PCT=$(jq -r '.total.lines.pct' "$SUMMARY")
BASE=$(jq -r --arg p "$PACKAGE" '.[$p]' "$BASELINE")

if [[ "$BASE" == "null" ]]; then
  echo "::notice::No $PACKAGE coverage baseline yet — measured ${PCT}% lines. Pin it in .github/coverage-baseline.json to arm the ratchet."
  exit 0
fi

if awk -v p="$PCT" -v b="$BASE" 'BEGIN { exit !(p < b - 0.1) }'; then
  echo "FAIL: $PACKAGE line coverage ${PCT}% is below the ${BASE}% floor in .github/coverage-baseline.json."
  echo "Add tests to cover your change, or (senior judgment only) apply the coverage-override label / lower the floor in a reviewed diff."
  exit 1
fi

if awk -v p="$PCT" -v b="$BASE" 'BEGIN { exit !(p > b + 0.1) }'; then
  echo "::notice::$PACKAGE coverage rose to ${PCT}% (floor ${BASE}%) — consider bumping the floor in .github/coverage-baseline.json in this PR to lock in the gain."
fi

echo "PASS: $PACKAGE line coverage ${PCT}% >= floor ${BASE}%"
