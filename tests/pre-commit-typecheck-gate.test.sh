#!/usr/bin/env bash
#
# Self-test for the typecheck configuration gate in template/.githooks/pre-commit.
#
# The gate exists because the template's typecheck block used to ship COMMENTED
# OUT under an "EDIT PER STACK" banner, and four of the six repos carrying the
# hook never adapted it. In those repos the hook ran, exited 0, and printed
# "Pre-commit checks passed" having verified nothing — which reads exactly like a
# gate that ran and approved the change. A type error rode that false assurance
# into tissue-core's main and broke three consecutive deploys on 2026-08-25.
#
# So the property under test is not "the typecheck runs". It is: an UNADAPTED
# template refuses to commit, and a repo that has made a deliberate choice —
# either filling the block in or opting out — is not obstructed.
#
# Like the branch-guard suite next door, this drives real `git commit` against
# throwaway repos rather than calling the hook directly: the failure modes that
# matter are in the wiring, and calling the script by hand would pass while the
# wiring was broken.
#
# Deliberately NOT `set -e`: we want every assertion to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../template/.githooks/pre-commit"
TMP="$(mktemp -d /tmp/typecheck-gate-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

git_c() { git -c user.email=t@t.t -c user.name=t "$@"; }

# <name> [sed-program-to-adapt-the-hook]
# Repos are created on a feature branch: the branch guard runs FIRST and would
# otherwise mask everything this suite is about.
new_repo() {
  local work="$TMP/$1"; local adapt="${2:-}"
  git_c init -q -b main "$work"
  mkdir -p "$work/.githooks"
  cp "$HOOK" "$work/.githooks/pre-commit"
  [[ -n "$adapt" ]] && sed -i "$adapt" "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"
  git_c -C "$work" config core.hooksPath .githooks
  echo base > "$work/base.txt"
  git_c -C "$work" add -A >/dev/null
  git_c -C "$work" commit -qm base --no-verify >/dev/null
  git_c -C "$work" checkout -q -b feat/work
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

# The three states, expressed as edits a consuming repo would really make.
SET_NONE='s/^TYPECHECK=unconfigured$/TYPECHECK=none/'
SET_CONFIGURED='s/^TYPECHECK=unconfigured$/TYPECHECK=configured/'


# --- the whole point: unadapted refuses ---------------------------------------
W="$(new_repo unadapted)"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "an UNADAPTED template refuses the commit" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" \
  "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"

# The refusal has to teach, or it just gets --no-verify'd forever.
grep -qi "typecheck" "$TMP/out"
check "...and the refusal says what is unconfigured" $?
grep -q "TYPECHECK=" "$TMP/out"
check "...and names the knob to set" $?
grep -q "none" "$TMP/out"
check "...and names the opt-out for repos with no typecheck" $?
grep -q -- "--no-verify" "$TMP/out"
check "...and names the escape hatch" $?

# The regression that started all this: a hook that verifies nothing must never
# claim it did.
grep -qv "Pre-commit checks passed" "$TMP/out" && ! grep -q "Pre-commit checks passed" "$TMP/out"
check "...and does NOT print 'checks passed'" $?


# --- an explicit opt-out is honoured -------------------------------------------
# A repo with genuinely no typecheck (a pure-bash repo) must be able to say so
# and keep committing. This is what stops the gate being --no-verify'd away.
W="$(new_repo optout "$SET_NONE")"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "an explicit opt-out (none) allows the commit" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and it landed" \
  "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"

# Honesty check: opting out means nothing was verified, so the hook must not
# claim a passing gate. This is the false-assurance defect, in its legal form.
! grep -q "Pre-commit checks passed" "$TMP/out"
check "...and it does not claim 'checks passed' when nothing ran" $?


# --- a configured repo actually runs its typecheck -----------------------------
# Fill the block in with a command that FAILS, and assert the commit is refused:
# that proves the block is wired to the outcome, not merely present. A passing
# stub would look identical to a block that is never executed.
W="$(new_repo configured_fails "$SET_CONFIGURED")"
cat >> "$W/.githooks/pre-commit" <<'EOF'
EOF
# Insert a failing "typecheck" into the configured block.
sed -i 's|^  : # <-- replace with your stack.*$|  (exit 3)|' "$W/.githooks/pre-commit"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a configured repo whose typecheck FAILS is refused" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" \
  "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"

W="$(new_repo configured_passes "$SET_CONFIGURED")"
sed -i 's|^  : # <-- replace with your stack.*$|  true|' "$W/.githooks/pre-commit"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a configured repo whose typecheck PASSES commits" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and it landed" \
  "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"
grep -q "Pre-commit checks passed" "$TMP/out"
check "...and NOW 'checks passed' is truthful, so it prints" $?


# --- a typecheck never runs in a tree without installed dependencies -----------
# A bare `npx <tool>` in a dependency-less worktree does not fail: it downloads
# the newest published <tool> and runs that (tissue-core 2026-09-30: `npx prisma
# generate` fetched prisma@8.0.0-rc.19). So the template's helper must refuse
# BEFORE any typecheck command runs. The marker file is what proves "before":
# a refusal that still ran the command would leave it behind.

# <workdir> <typecheck lines...> — swap the placeholder for real lines.
fill_typecheck_block() {
  local work=$1; shift
  local body; body="$(printf '  %s\n' "$@")"
  awk -v body="$body" '/^  : # <-- replace with your stack/ { print body; next } { print }' \
    "$work/.githooks/pre-commit" > "$work/.githooks/pre-commit.new"
  mv "$work/.githooks/pre-commit.new" "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"
  git_c -C "$work" commit -qam "fill typecheck block" --no-verify >/dev/null 2>&1 || true
}

# node_modules must never be staged itself, or `mkdir node_modules` below would
# turn into a diff the commit then carries.
new_deps_repo() { # <name> <typecheck lines...>
  local name=$1; shift
  local work; work="$(new_repo "$name" "$SET_CONFIGURED")"
  echo node_modules > "$work/.gitignore"
  fill_typecheck_block "$work" "$@"
  echo "$work"
}

MARK='touch "$ROOT/.typecheck-ran"'

W="$(new_deps_repo deps_missing 'require_installed_deps pkg' "$MARK")"
rc="$(try_commit "$W")"
check "no node_modules: the commit is refused" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
grep -q "dependencies not installed in: pkg" "$TMP/out"
check "...and the refusal names the package" $?
grep -q "setup-worktree.sh" "$TMP/out"
check "...and points at the installer" $?
grep -q -- "--no-verify" "$TMP/out"
check "...and names the escape hatch" $?
check "...and the typecheck command never ran" \
  "$([[ ! -e "$W/.typecheck-ran" ]] && echo 0 || echo 1)"

W="$(new_deps_repo deps_present 'require_installed_deps pkg' "$MARK")"
mkdir -p "$W/pkg/node_modules"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "node_modules present: healthy path exits 0" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and the commit landed" \
  "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"
check "...and the typecheck command DID run" \
  "$([[ -e "$W/.typecheck-ran" ]] && echo 0 || echo 1)"

W="$(new_deps_repo deps_partial 'require_installed_deps backend frontend' "$MARK")"
mkdir -p "$W/backend/node_modules"
rc="$(try_commit "$W")"
check "one of two packages missing: refused" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
grep -q "dependencies not installed in: frontend$" "$TMP/out"
check "...and the refusal names only the missing package" $?
check "...and the typecheck command never ran" \
  "$([[ ! -e "$W/.typecheck-ran" ]] && echo 0 || echo 1)"


# --- the escape hatch still works ---------------------------------------------
# Fail-closed must not mean fail-stuck: a mid-rebase fixup on a machine without
# node_modules has to remain possible.
W="$(new_repo bypass)"
rc="$(try_commit "$W" --no-verify)"
check "--no-verify bypasses the unconfigured refusal" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"


# --- ordering: the branch guard still wins -------------------------------------
# A commit on a protected branch must report THAT, not the typecheck gate. The
# branch guard is a policy refusal and there is no reason to spend seconds — or
# emit a confusing diagnosis — on a commit that must not exist.
W="$(new_repo ordering)"
git_c -C "$W" checkout -q main
try_commit "$W" >/dev/null
grep -q "refusing to commit on 'main'" "$TMP/out"
check "on a protected branch, the BRANCH guard reports first" $?
! grep -qi "typecheck" "$TMP/out"
check "...and the typecheck gate stays quiet there" $?


# --- the file itself ----------------------------------------------------------
bash -n "$HOOK"
check "the template hook parses as valid bash" $?

grep -q '^TYPECHECK=unconfigured$' "$HOOK"
check "the SHIPPED template is unconfigured (fails closed on arrival)" $?


echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
