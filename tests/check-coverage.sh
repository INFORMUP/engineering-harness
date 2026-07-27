#!/usr/bin/env bash
# Coverage manifest gate for the template gate scripts.
#
# Asserts that every script shipped under template/.github/scripts/ has a
# matching self-test in tests/, named <script-basename>.test.<ext>
# (e.g. coverage-ratchet.sh -> tests/coverage-ratchet.test.sh,
#        schema-comment-check.mjs -> tests/schema-comment-check.test.mjs).
#
# This is what makes the self-test suite a real guarantee rather than opt-in.
# The workflow discovers and runs whatever tests exist by glob, so a NEW gate
# script added with no test would leave CI green (the runner simply finds no
# new test to run) and the untested script would fan out to every consumer on
# the next `install.sh` sync — the exact silent gap the self-tests exist to
# close, one level up. This gate turns "every test we remembered to write
# runs" into "every shipped script is tested, or CI is red."
#
# Runnable locally: bash tests/check-coverage.sh
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/template/.github/scripts"
TESTS_DIR="$REPO_ROOT/tests"

missing=0
found=0

for script in "$SCRIPTS_DIR"/*; do
  [[ -f "$script" ]] || continue
  found=$((found + 1))
  base="$(basename "$script")"
  name="${base%.*}" # strip the single trailing extension

  # A matching test is tests/<name>.test.<anything> — the test keeps its own
  # extension (.mjs for node, .sh for bash), independent of the script's.
  shopt -s nullglob
  matches=("$TESTS_DIR/$name".test.*)
  shopt -u nullglob

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "::error::no self-test for template/.github/scripts/$base (expected tests/$name.test.*)"
    missing=1
  else
    echo "OK: $base -> $(basename "${matches[0]}")"
  fi
done

# Guard against a silent pass if the scripts directory ever moves or empties:
# a loop over zero files would otherwise report success having checked nothing.
if [[ "$found" -eq 0 ]]; then
  echo "::error::no scripts found under template/.github/scripts/ — check the path"
  exit 1
fi

if [[ "$missing" -ne 0 ]]; then
  echo
  echo "coverage manifest: FAIL — every gate script needs a matching tests/<name>.test.* self-test"
  exit 1
fi

echo
echo "coverage manifest: OK — all $found script(s) have a self-test"
exit 0
