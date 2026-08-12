#!/usr/bin/env bash
# Self-test for the "is the target a git repo?" guard in scripts/install.sh
# and scripts/install-module.sh.
#
# Hermetic: builds real git repos in a temp dir and runs each installer against
# them. No network, no npm.
#
# The case that matters is a **linked worktree**, where `.git` is a FILE
# containing a `gitdir:` pointer rather than a directory. Every INFORMUP repo is
# worked in worktrees by convention, so a guard that only accepts a directory
# rejects the normal way these installers get used — while still accepting a
# bare directory that merely happens to contain a `.git` folder. The guard is
# checked in both directions here: real worktrees in, non-repos out.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$SELF_DIR/../scripts/install.sh"
INSTALL_MODULE="$SELF_DIR/../scripts/install-module.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 ($2)"; }

# Builds a git repo with one commit and a linked worktree beside it.
# Echoes the temp root; "$root/repo" is the primary, "$root/wt" the worktree.
make_repo_with_worktree() {
  local root
  root="$(mktemp -d)"
  git init -q "$root/repo"
  git -C "$root/repo" config user.email t@example.com
  git -C "$root/repo" config user.name Test
  echo hello >"$root/repo/README.md"
  git -C "$root/repo" add -A
  git -C "$root/repo" commit -qm init
  git -C "$root/repo" worktree add -q -b side "$root/wt" >/dev/null 2>&1
  echo "$root"
}

# Runs an installer against a target, echoing "<exit-code>|<combined output>".
run_installer() {
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  echo "$rc|$out"
}

# --- the guard accepts a linked worktree ------------------------------------

check_accepts_worktree() {
  local label="$1" installer_desc="$2"
  shift 2
  local result rc
  result="$(run_installer "$@")"
  rc="${result%%|*}"
  if [[ "$rc" -eq 0 ]] && [[ "$result" != *"is not a git repo"* ]]; then
    pass "$label"
  else
    fail "$label" "$installer_desc rejected a linked worktree: ${result#*|}"
  fi
}

# --- the guard still rejects a plain directory ------------------------------

check_rejects_non_repo() {
  local label="$1"
  shift
  local result rc
  result="$(run_installer "$@")"
  rc="${result%%|*}"
  if [[ "$rc" -ne 0 ]] && [[ "$result" == *"is not a git repo"* ]]; then
    pass "$label"
  else
    fail "$label" "expected a 'not a git repo' refusal, got: ${result#*|}"
  fi
}

root="$(make_repo_with_worktree)"
check_accepts_worktree \
  "install.sh accepts a linked worktree (.git is a file, not a directory)" \
  "install.sh" \
  bash "$INSTALL" "$root/wt"
rm -rf "$root"

root="$(make_repo_with_worktree)"
check_accepts_worktree \
  "install-module.sh accepts a linked worktree" \
  "install-module.sh" \
  bash "$INSTALL_MODULE" taskflow "$root/wt"
rm -rf "$root"

# A plain directory is still refused — the point is to widen the guard to the
# other shape a git checkout takes, not to remove it.
root="$(mktemp -d)"
mkdir -p "$root/plain"
check_rejects_non_repo \
  "install.sh still refuses a directory that is not a checkout" \
  bash "$INSTALL" "$root/plain"
check_rejects_non_repo \
  "install-module.sh still refuses a directory that is not a checkout" \
  bash "$INSTALL_MODULE" taskflow "$root/plain"
rm -rf "$root"

echo
echo "install target check: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
