#!/usr/bin/env bash
#
# Self-test for the docs-only short-circuit in template/.githooks/pre-commit.
#
# A fresh worktree (this repo's own committing convention — see the top-level
# CLAUDE.md) has no node_modules and no adapted build tooling until someone
# runs the real setup. That is fine for code work, which needs those things
# anyway, but it turns a plain markdown commit — a worklog entry, a doc fix —
# into a wall the typecheck and reuse-inventory blocks put up for no reason:
# neither block can possibly have anything to say about a change that touches
# no code. Hit for real on 2026-08-29 committing a worklog entry in
# tissue-core, and worked around with `--no-verify`, which is exactly the
# habit this hook exists to discourage.
#
# So the property under test is not "docs commits are fast". It is: a commit
# whose staged paths are ENTIRELY markdown/docs skips the typecheck and
# inventory-regeneration blocks (real skip, not incidental pass — proven by
# making the typecheck command one that would fail if it ran), while a commit
# that touches ANY non-doc path — including one that only DELETES a code file
# — still runs them, and Prettier's format:check keeps running regardless
# because it genuinely does apply to markdown.
#
# Like its siblings, this drives real `git commit` against throwaway repos
# rather than calling the hook directly: the failure modes that matter are in
# the wiring (staged-path detection, rename handling, ordering against the
# branch guard) and calling the script by hand would pass while any of that
# was broken.
#
# Deliberately NOT `set -e`: we want every assertion to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../template/.githooks/pre-commit"
TMP="$(mktemp -d /tmp/docs-only-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

git_c() { git -c user.email=t@t.t -c user.name=t "$@"; }

# A repo whose typecheck command FAILS if it ever runs. That is what makes a
# passing docs-only commit here proof that the block was skipped, rather than
# proof the placeholder happened to be a no-op.
SET_CONFIGURED_FAILING='s/^TYPECHECK=unconfigured$/TYPECHECK=configured/'

# Repos are created on a feature branch: the branch guard runs FIRST and would
# otherwise mask everything this suite is about.
new_repo() { # <name>
  local work="$TMP/$1"
  git_c init -q -b main "$work"
  mkdir -p "$work/.githooks"
  cp "$HOOK" "$work/.githooks/pre-commit"
  sed -i "$SET_CONFIGURED_FAILING" "$work/.githooks/pre-commit"
  sed -i 's|^  : # <-- replace with your stack.*$|  (exit 1)|' "$work/.githooks/pre-commit"
  chmod +x "$work/.githooks/pre-commit"
  git_c -C "$work" config core.hooksPath .githooks
  echo base > "$work/base.txt"
  mkdir -p "$work/docs" "$work/src"
  echo "# Docs" > "$work/docs/existing.md"
  echo "existing" > "$work/src/existing.ts"
  git_c -C "$work" add -A >/dev/null
  git_c -C "$work" commit -qm base --no-verify >/dev/null
  git_c -C "$work" checkout -q -b feat/work
  echo "$work"
}

try_commit() { # <workdir> [extra args]
  local work=$1; shift
  git_c -C "$work" commit -m attempt "$@" >"$TMP/out" 2>&1
  echo $?
}

n_commits() { git_c -C "$1" rev-list --count HEAD; }


# --- a .md-only change is docs-only and commits despite a failing typecheck ---
W="$(new_repo md_only)"
echo "doc update" >> "$W/docs/existing.md"
git_c -C "$W" add -A >/dev/null
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a staged .md-only change commits despite a typecheck that would fail" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and it landed" "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"
grep -qi "docs-only" "$TMP/out"
check "...and the output names the reason it skipped code gates" $?
! grep -q "Pre-commit checks passed" "$TMP/out"
check "...and (with no format:check configured) it does not claim checks passed" $?


# --- a non-.md docs/ path is likewise docs-only --------------------------------
W="$(new_repo docs_dir_non_md)"
echo "notes" > "$W/docs/notes.txt"
git_c -C "$W" add -A >/dev/null
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a staged docs/ path that is not .md is treated as docs-only" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
check "...and it landed" "$([[ "$(n_commits "$W")" -eq $((before+1)) ]] && echo 0 || echo 1)"


# --- mixed .md + code still runs (and fails) the typecheck ---------------------
W="$(new_repo mixed)"
echo "doc update" >> "$W/docs/existing.md"
echo "change" >> "$W/src/existing.ts"
git_c -C "$W" add -A >/dev/null
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a mixed .md+.ts commit still runs the typecheck and is refused" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"


# --- a code-only commit is unaffected (unchanged behaviour) --------------------
W="$(new_repo code_only)"
echo "change" >> "$W/src/existing.ts"
git_c -C "$W" add -A >/dev/null
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a code-only commit still runs the typecheck and is refused" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"


# --- deleting a code file while staging only a doc edit is NOT docs-only -------
# --diff-filter must not be used: a deletion carries no destination content to
# judge by extension, but it is still a real code change and must still run
# the typecheck. Without --no-renames a delete+add pair could also register as
# a rename and be misjudged the same way a genuine rename would be.
W="$(new_repo delete_code)"
echo "doc update" >> "$W/docs/existing.md"
git_c -C "$W" rm -q "$W/src/existing.ts"
git_c -C "$W" add -A >/dev/null
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "deleting a code file (with only a doc edit also staged) is NOT docs-only" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"


# --- an empty staged list is not docs-only (falls through to normal path) -----
# Nothing to compute a verdict from, so an empty commit must fall through to
# the ordinary (here: configured-and-failing) typecheck path rather than being
# waved through as vacuously docs-only.
W="$(new_repo empty_stage)"
rc="$(git_c -C "$W" commit --allow-empty -m attempt >"$TMP/out" 2>&1; echo $?)"
check "an empty staged list is refused (falls through to the normal typecheck path)" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"


# --- ordering: the branch guard still wins even on a docs-only commit ---------
W="$(new_repo ordering)"
git_c -C "$W" checkout -q main
echo "doc update" >> "$W/docs/existing.md"
git_c -C "$W" add -A >/dev/null
try_commit "$W" >/dev/null
grep -q "refusing to commit on 'main'" "$TMP/out"
check "on a protected branch, the BRANCH guard reports first even for docs-only" $?
! grep -qi "docs-only" "$TMP/out"
check "...and the docs-only skip message stays quiet there" $?


# --- rename detection must stay off, or a rename to docs/ hides real code -----
# api/foo.ts renamed to docs/foo.md must be judged as the code file it is
# (git diff --no-renames reports both the deletion and the addition), not as a
# docs-only add. Renamed content itself is still text a human might read as
# "docs", so put code-shaped content in the renamed file to make sure a
# rename-into-docs is never mistaken for a doc edit.
W="$(new_repo rename_into_docs)"
echo "export const x = 1;" > "$W/src/moved.ts"
git_c -C "$W" add -A >/dev/null
git_c -C "$W" commit -qm "add moved.ts" --no-verify >/dev/null
git_c -C "$W" mv "src/moved.ts" "docs/moved.md"
before="$(n_commits "$W")"
rc="$(try_commit "$W")"
check "a rename from code into docs/ is NOT treated as docs-only" \
  "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
check "...and creates no commit" "$([[ "$(n_commits "$W")" == "$before" ]] && echo 0 || echo 1)"


# --- the summary must not overstate a docs-only pass ---------------------------
# A repo WITH a formatter runs one real gate on a docs-only commit (Prettier
# formats markdown), so "nothing verified" would be false — but so would a bare
# "checks passed", which reads as though the code gates ran too. The line has to
# say both: something passed, and the code gates were skipped.
W="$(new_repo docs_only_with_formatter)"
cat > "$W/package.json" <<'JSON'
{ "name": "t", "scripts": { "format:check": "true" } }
JSON
git_c -C "$W" add -A >/dev/null
git_c -C "$W" commit -qm "add package.json" --no-verify >/dev/null
echo "doc update" >> "$W/docs/existing.md"
git_c -C "$W" add -A >/dev/null
rc="$(try_commit "$W")"
check "a docs-only commit still runs the formatter and lands" \
  "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
grep -q "code gates skipped" "$TMP/out"
check "...and the pass is qualified, not reported as a full green" $?


# --- the file itself -----------------------------------------------------------
bash -n "$HOOK"
check "the template hook parses as valid bash" $?

grep -q -- '--no-renames' "$HOOK"
check "the hook computes docs-only from a --no-renames diff" $?


echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
