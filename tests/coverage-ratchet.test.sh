#!/usr/bin/env bash
# Self-test for template/.github/scripts/coverage-ratchet.sh
#
# Hermetic: each case builds its own temp dir with a coverage-baseline.json
# and a coverage-summary.json, then invokes the script with cwd set to the
# fake package dir, exactly as CI would.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../template/.github/scripts/coverage-ratchet.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1 ($2)"
}

# assert_case <name> <key> <pct> <create_summary: yes|no> <expected_rc> <must_contain...>
# Trailing args (after expected_rc) are substrings that must appear in output;
# prefix one with "!" to assert it must NOT appear.
assert_case() {
  local name="$1" key="$2" pct="$3" create_summary="$4" expected_rc="$5"
  shift 5

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/.github" "$tmp/pkg/coverage"
  cat >"$tmp/.github/coverage-baseline.json" <<'JSON'
{"backend": 80, "frontend": null}
JSON

  if [[ "$create_summary" == "yes" ]]; then
    printf '{"total":{"lines":{"pct":%s}}}' "$pct" >"$tmp/pkg/coverage/coverage-summary.json"
  fi

  local out
  out="$(cd "$tmp/pkg" && bash "$SCRIPT" "$key" 2>&1)"
  local rc=$?

  local ok=1
  local detail=""

  if [[ "$rc" -ne "$expected_rc" ]]; then
    ok=0
    detail="expected rc $expected_rc, got $rc; output: $out"
  fi

  local check
  for check in "$@"; do
    if [[ "$check" == "!"* ]]; then
      local needle="${check:1}"
      if [[ "$out" == *"$needle"* ]]; then
        ok=0
        detail="output unexpectedly contained '$needle'; output: $out"
      fi
    else
      if [[ "$out" != *"$check"* ]]; then
        ok=0
        detail="output missing '$check'; output: $out"
      fi
    fi
  done

  if [[ "$ok" -eq 1 ]]; then
    pass "$name"
  else
    fail "$name" "$detail"
  fi
}

assert_case "null baseline is report-only" \
  "frontend" 50 yes 0 \
  "No frontend coverage baseline"

assert_case "coverage rose above floor nudges to bump it" \
  "backend" 85 yes 0 \
  "PASS" "rose"

assert_case "coverage exactly at floor passes without a nudge" \
  "backend" 80 yes 0 \
  "PASS" "!rose"

assert_case "coverage within 0.1 tolerance below floor passes" \
  "backend" 79.95 yes 0 \
  "PASS"

assert_case "coverage below floor beyond tolerance fails" \
  "backend" 79.8 yes 1 \
  "below the 80% floor"

assert_case "missing coverage-summary.json fails" \
  "backend" 0 no 1 \
  "not found"

echo
echo "coverage-ratchet self-test: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
