#!/usr/bin/env bash
#
# Self-test for the protected-branch guard in template/.githooks/pre-commit.
#
# Drives real `git commit` against throwaway repos rather than calling the hook
# directly. The failure modes that matter are in the WIRING — whether a relative
# core.hooksPath resolves from the worktree root, whether the hook is found from a
# subdirectory, whether it fires inside a linked worktree, whether --no-verify still
# bypasses. Invoking the script by hand would pass while all of those were broken.
#
# The repos here carry no package.json and no scripts/, so every later block in the
# hook short-circuits on its own `[[ -f ... ]]` guard and only the branch guard runs.
#
# Deliberately NOT `set -e`: we want every assertion to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../template/.githooks/pre-commit"
TMP="$(mktemp -d /tmp/branch-guard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

git_c() { git -c user.email=t@t.t -c user.name=t "$@"; }

new_repo() { # <name> <initial-branch>
  local work="$TMP/$1"
  git_c init -q -b "${2:-main}" "$work"
  mkdir -p "$work/.githooks"
  cp "$HOOK" "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"
  git_c -C "$work" config core.hooksPath .githooks
  echo base > "$work/base.txt"
  git_c -C "$work" add -A >/dev/null
  git_c -C "$work" commit -qm base --no-verify >/dev/null
  echo "$work"
}

try_commit() { # <workdir> [extra args]
  local work=$1; shift
  echo "c-$RANDOM" >> "$work/base.txt"
  git_c -C "$work" add -A >/dev/null
  git_c -C "$work" commit -m attempt "$@" >"$TMP/out" 2>&1
  echo $?
}

n_commits() { git_c -C "$1" rev-list --count HEAD; }


# --- defaults: main / master / staging are all refused ------------------------
for br in main master staging; do
  W="$(new_repo "def-$br" "$br")"
  before="$(n_commits "$W")"
  rc="$(try_commit "$W")"
  check "a commit on '$br' is refused by default" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
  check "...and created no commit on '$br'" \
    "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"
done

# The staging case is the one that distinguishes this from a main-only guard:
# reportal / ghost / dashboard-backend integrate there, not on main.
W="$(new_repo msg staging)"
try_commit "$W" >/dev/null
grep -q "refusing to commit on 'staging'" "$TMP/out"
check "the refusal names the actual branch, not a hardcoded one" $?
grep -q "git worktree add -b" "$TMP/out"
check "...and prints the worktree recovery command" $?
grep -q -- "--no-verify" "$TMP/out"
check "...and names the escape hatch" $?
grep -q "informup.protectedBranches" "$TMP/out"
check "...and names the override knob" $?


# --- what must still work -----------------------------------------------------
W="$(new_repo feat main)"
git_c -C "$W" checkout -q -b feat/thing
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a commit on a feature branch is allowed" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and it landed" "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"

W="$(new_repo bypass main)"
rc="$(try_commit "$W" --no-verify)"
check "--no-verify bypasses the guard" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

W="$(new_repo detach main)"
git_c -C "$W" checkout -q --detach HEAD
rc="$(try_commit "$W")"
check "a detached HEAD is not blocked (rebase/bisect must still work)" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"


# --- the per-repo override ----------------------------------------------------
# A repo whose integration branch is neither main nor staging must be able to say so
# without editing the shared template.
W="$(new_repo override main)"
git_c -C "$W" config informup.protectedBranches "develop"
rc="$(try_commit "$W")"
check "overriding the list un-protects main" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

git_c -C "$W" checkout -q -b develop
rc="$(try_commit "$W")"
check "...and protects the branch named in the override" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"


# --- wiring -------------------------------------------------------------------
W="$(new_repo subdir main)"
mkdir -p "$W/a/b"; echo x > "$W/a/b/f.txt"; git_c -C "$W" add -A >/dev/null
( cd "$W/a/b" && git_c commit -m sub ) >"$TMP/out" 2>&1
check "the guard fires when committing from a subdirectory" \
  "$([[ $? -ne 0 ]] && echo 0 || echo 1)"

W="$(new_repo wt main)"
git_c -C "$W" worktree add -q -b feat/in-wt "$TMP/wt-linked" >/dev/null 2>&1
rc="$(try_commit "$TMP/wt-linked")"
check "a linked worktree on a feature branch is not obstructed" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

W="$(new_repo wt2 main)"
git_c -C "$W" checkout -q --detach HEAD
git_c -C "$W" worktree add -q "$TMP/wt-on-main" main >/dev/null 2>&1
rc="$(try_commit "$TMP/wt-on-main")"
check "a linked worktree sitting on a protected branch is blocked too" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"


# --- the file itself ----------------------------------------------------------
bash -n "$HOOK"
check "the template hook parses as valid bash" $?


echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
