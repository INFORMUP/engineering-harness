#!/usr/bin/env bash
# Self-test for template/.github/scripts/claude-sections-check.sh — the gate
# asserting the harness's shared CLAUDE.md sections were actually spliced into
# a consumer repo.
#
# Hermetic: every case builds a real git repo in a temp dir. No network, no npm.
#
# Two cases carry most of the value:
#
#   * "a heading is missing" — the gate's whole reason for existing. The check
#     it replaced (is the copied file gone?) passed in all six consumer repos
#     while the content had never been merged, so a gate that only proves
#     absence of the source file proves nothing.
#
#   * "a '#' comment is not read as a heading" — the manifest's comment marker
#     and its heading marker overlap by one character, so a naive
#     comment-stripping pass eats the entire manifest and the gate then passes
#     vacuously on any repo. The vacuous-manifest guard is tested alongside it.
#
# The last case pins the manifest to the template it is derived from, so a
# section added to CLAUDE-sections.md without a manifest line fails here rather
# than silently never reaching a consumer — the same failure one level up.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CHECK="$REPO_ROOT/template/.github/scripts/claude-sections-check.sh"
TEMPLATE_MANIFEST="$REPO_ROOT/template/.github/claude-sections.manifest"
TEMPLATE_SECTIONS="$REPO_ROOT/template/CLAUDE-sections.md"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 ($2)"; }

# Build a consumer-shaped repo: a git checkout with a manifest and a CLAUDE.md.
# Echoes the repo path. Args: <manifest-content> <claude-md-content>
make_repo() {
  local manifest="$1" claude_md="$2" root
  root="$(mktemp -d)"
  git init -q "$root"
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name Test
  mkdir -p "$root/.github/scripts"
  [[ "$manifest" != "<none>" ]] && printf '%s\n' "$manifest" >"$root/.github/claude-sections.manifest"
  [[ "$claude_md" != "<none>" ]] && printf '%s\n' "$claude_md" >"$root/CLAUDE.md"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -qm init >/dev/null 2>&1 || true
  echo "$root"
}

# Echo "<exit-code>|<combined output>" for the gate run against a repo.
run_check() {
  local out rc
  out="$(bash "$CHECK" "$1" 2>&1)"
  rc=$?
  echo "$rc|$out"
}

expect_pass() {
  local label="$1" repo="$2" result rc
  result="$(run_check "$repo")"
  rc="${result%%|*}"
  if [[ "$rc" -eq 0 ]]; then pass "$label"; else fail "$label" "expected exit 0, got $rc: ${result#*|}"; fi
}

# expect_fail <label> <repo> <substring the output must contain>
expect_fail() {
  local label="$1" repo="$2" needle="$3" result rc out
  result="$(run_check "$repo")"
  rc="${result%%|*}"
  out="${result#*|}"
  if [[ "$rc" -ne 0 ]] && [[ "$out" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "expected non-zero exit and output containing '$needle', got rc=$rc: $out"
  fi
}

TWO_SECTION_MANIFEST='# a comment that must not be read as a heading
## Worklog
## Tenant scoping'

# --- the happy path ---------------------------------------------------------

repo="$(make_repo "$TWO_SECTION_MANIFEST" '# Repo

## Worklog
Anything at all under here.

## Tenant scoping
Repo-specific prose, deliberately not the template wording.')"
expect_pass "passes when every listed heading is present" "$repo"
rm -rf "$repo"

# --- the case the old shape missed ------------------------------------------

repo="$(make_repo "$TWO_SECTION_MANIFEST" '# Repo

## Worklog
Only one of the two.')"
expect_fail "fails, naming the section, when a heading is missing" "$repo" "missing the harness section: ## Tenant scoping"
rm -rf "$repo"

# The precise shape of the six-repo failure: the installer's copy is gone, and
# the content was never merged. Absence of the source file must not be read as
# evidence the splice happened.
repo="$(make_repo "$TWO_SECTION_MANIFEST" '# Repo

Nothing was ever spliced here.')"
expect_fail "fails when the copy is gone but nothing was spliced" "$repo" "HARNESS SECTIONS NOT SPLICED"
rm -rf "$repo"

# --- the manifest comment/heading collision ---------------------------------

repo="$(make_repo '# just a comment
# ## Worklog is mentioned in this comment
## Worklog' '# Repo

## Worklog
Present.')"
expect_pass "reads '## ' lines as headings and ignores '#' comments" "$repo"
rm -rf "$repo"

repo="$(make_repo '# every line here is a comment
# nothing is required' '# Repo

Nothing spliced.')"
expect_fail "refuses a manifest with no headings instead of passing vacuously" "$repo" "lists no '## ' headings"
rm -rf "$repo"

# --- matching is whole-line ------------------------------------------------

repo="$(make_repo '## Code Style' '# Repo

## Code Style Guide
A longer heading must not satisfy the shorter requirement.')"
expect_fail "does not accept a longer heading as a match" "$repo" "missing the harness section: ## Code Style"
rm -rf "$repo"

repo="$(make_repo '## Worklog' '# Repo

We mention ## Worklog inside a sentence, which is not a section.')"
expect_fail "does not accept a heading quoted mid-prose" "$repo" "missing the harness section: ## Worklog"
rm -rf "$repo"

# --- missing inputs ---------------------------------------------------------

repo="$(make_repo "$TWO_SECTION_MANIFEST" '<none>')"
expect_fail "fails when the repo has no CLAUDE.md at all" "$repo" "no CLAUDE.md at the repo root"
rm -rf "$repo"

repo="$(make_repo '<none>' '# Repo')"
expect_fail "fails when the manifest was never installed" "$repo" "no manifest"
rm -rf "$repo"

# --- the stale leftover -----------------------------------------------------

repo="$(make_repo '## Worklog' '# Repo

## Worklog
Spliced.')"
printf '# stale copy\n' >"$repo/CLAUDE-sections.md"
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" commit -qm leftover >/dev/null 2>&1
expect_fail "fails on a tracked leftover copy even when the splice is complete" "$repo" "delete the installer's copy once spliced"
rm -rf "$repo"

# --- the manifest tracks the template it is derived from --------------------

template_headings="$(grep -E '^## ' "$TEMPLATE_SECTIONS" | sort)"
manifest_headings="$(grep -E '^## ' "$TEMPLATE_MANIFEST" | sort)"
if [[ "$template_headings" == "$manifest_headings" ]]; then
  pass "the shipped manifest lists exactly the template's own sections"
else
  fail "the shipped manifest lists exactly the template's own sections" \
    "manifest and CLAUDE-sections.md disagree:$(printf '\n')$(diff <(echo "$template_headings") <(echo "$manifest_headings"))"
fi

echo
echo "claude sections check: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
