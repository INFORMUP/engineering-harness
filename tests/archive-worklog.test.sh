#!/usr/bin/env bash
#
# Tests for .github/scripts/archive-worklog.sh.
#
# Two halves. The first sources the script with ARCHIVE_WORKLOG_SOURCE_ONLY=1
# so `main` never runs, and checks the pure naming logic. The second builds
# throwaway git repositories under a temp dir and drives the real script
# against them end to end — so it never touches this checkout, and the cases
# that matter (a citation actually rewritten, a dry run changing nothing) are
# observed rather than inferred.
# Run: ./scripts/ops/archive-worklog.test.sh
#
# Deliberately NOT `set -e`: every assertion should run even after one fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../template/.github/scripts/archive-worklog.sh"
TMP="$(mktemp -d /tmp/archive-worklog-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

ARCHIVE_WORKLOG_SOURCE_ONLY=1 source "$SCRIPT"
set +e
set -uo pipefail

# ------------------------------------------------------------
# Naming
# ------------------------------------------------------------

[[ "$(archive_name my-entry 2026-08-19-1344)" == "2026-08-19-1344-my-entry.md" ]]
check "the archive name carries the close timestamp then the slug" $?

# The checker matches ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}- on archived names; a
# name it does not recognise is a finding on the PR that archives the entry.
[[ "$(archive_name x "$(WORKLOG_ARCHIVE_TIMESTAMP=2026-01-02-0304 archive_timestamp)")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}- ]]
check "the generated prefix matches the checker's archive pattern" $?

[[ "$(archive_timestamp)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]
check "the real clock produces a conforming prefix too" $?

# Whatever the caller happened to have in hand from a grep must resolve to the
# same entry — a slug, a repo-relative path, a ./-prefixed one.
[[ "$(slug_from_arg my-entry)" == "my-entry" \
&& "$(slug_from_arg docs/worklog/my-entry.md)" == "my-entry" \
&& "$(slug_from_arg ./docs/worklog/my-entry.md)" == "my-entry" ]]
check "a slug, a path, and a ./path all name the same entry" $?

# ------------------------------------------------------------
# End to end, against throwaway repositories
# ------------------------------------------------------------

make_repo() { # <dir>
  local d="$1"
  mkdir -p "$d/docs/worklog" "$d/scripts/ops"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.org
  git -C "$d" config user.name Test
  cat > "$d/docs/worklog/an-entry.md" <<'ENTRY'
# An entry

- **Status:** open
- **Next action:** someone owes this a fix
- **Found:** 2026-08-01
- **Escalated:** no

## Observation
It does the wrong thing.

## Evidence
`foo.sh:1`

## Why it matters
Because.

## Resolution
Fixed by PR #1.
ENTRY
  # Three citing files, one of them a script — the fan-out this script exists for.
  echo 'See docs/worklog/an-entry.md for evidence.' > "$d/CLAUDE.md"
  echo '# see docs/worklog/an-entry.md' > "$d/scripts/ops/thing.sh"
  echo 'note: docs/worklog/an-entry.md' > "$d/docs/notes.md"
  # An untouched near-miss: a DIFFERENT entry whose name contains the first as a
  # prefix. A sloppy rewrite would corrupt it.
  echo 'docs/worklog/an-entry-that-continues.md' > "$d/other.md"
  git -C "$d" add -A && git -C "$d" commit -qm init
}

R1="$TMP/dry"; make_repo "$R1"
( cd "$R1" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry ) > "$TMP/dry.out" 2>&1
check "a dry run exits 0" $?

[[ -z "$(git -C "$R1" status --porcelain)" ]]
check "a dry run leaves the tree untouched" $?

grep -q "3 file(s) cite this entry" "$TMP/dry.out"
check "a dry run counts the citing files" $?

grep -q "DRY RUN" "$TMP/dry.out"
check "a dry run says so" $?

R2="$TMP/apply"; make_repo "$R2"
( cd "$R2" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry --apply ) > "$TMP/apply.out" 2>&1
check "an --apply run exits 0" $?

ARCHIVED="$R2/docs/worklog/archives/2026-08-19-1344-an-entry.md"
[[ -f "$ARCHIVED" && ! -f "$R2/docs/worklog/an-entry.md" ]]
check "the entry moves to archives/ under its timestamped name" $?

grep -q '^- \*\*Status:\*\* resolved$' "$ARCHIVED"
check "the status is stamped resolved" $?

# The rot the worklog conventions warn about: a closed entry whose header still
# says someone owes it something.
! grep -q 'someone owes this a fix' "$ARCHIVED"
check "a stale Next action does not survive the close" $?

# A wrapped Next action is one field, not one line. Rewriting only its first
# line leaves the tail welded onto the replacement — and the tail is the stale
# half, so an archived entry ends up asserting in the present tense that the
# closed thing is still owed something. Nothing downstream catches it: the
# first line is still well-formed, so the checker sees a valid header.
R7="$TMP/wrapped"; make_repo "$R7"
python3 - "$R7/docs/worklog/an-entry.md" <<'WRAP'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "- **Next action:** someone owes this a fix",
    "- **Next action:** someone owes this a fix, and the reason\n  runs past the width of one line\n  and then some",
))
WRAP
git -C "$R7" commit -qam "wrapped next action"
( cd "$R7" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry --apply ) >/dev/null 2>&1
WRAPPED="$R7/docs/worklog/archives/2026-08-19-1344-an-entry.md"
! grep -q 'runs past the width of one line' "$WRAPPED" \
  && ! grep -q 'and then some' "$WRAPPED"
check "a wrapped Next action is replaced whole, tail and all" $?

# The field ends where the next bullet begins; eating past it would take the
# rest of the header with it.
grep -q '^- \*\*Found:\*\* 2026-08-01$' "$WRAPPED"
check "the bullet after a wrapped Next action survives" $?

# The point of the whole script.
grep -q 'docs/worklog/archives/2026-08-19-1344-an-entry.md' "$R2/CLAUDE.md" \
  && grep -q 'docs/worklog/archives/2026-08-19-1344-an-entry.md' "$R2/scripts/ops/thing.sh" \
  && grep -q 'docs/worklog/archives/2026-08-19-1344-an-entry.md' "$R2/docs/notes.md"
check "every citation is repointed at the archived path" $?

! grep -rq 'docs/worklog/an-entry\.md' "$R2/CLAUDE.md" "$R2/scripts/ops/thing.sh" "$R2/docs/notes.md"
check "no citation is left pointing at the old path" $?

# A rewrite that matched on prefix would rename a different entry's citation,
# and the damage would land in a file nobody was looking at.
[[ "$(cat "$R2/other.md")" == "docs/worklog/an-entry-that-continues.md" ]]
check "a longer entry name that starts with this slug is not touched" $?

# The move must be staged as a rename, or `git status` shows a delete plus an
# untracked file and the history of the entry is lost at the archive boundary.
git -C "$R2" diff --cached --name-status | grep -q '^R'
check "the move is staged as a git rename, preserving the entry's history" $?

# ...and every edit the script makes must be staged along with it. `git mv`
# renames the INDEX ENTRY, carrying the pre-edit blob under the new name, so a
# status stamp and citation rewrites made in the working tree are left unstaged
# behind it. Nothing local catches that: check-worklog.sh reads the working
# tree and passes, so a `git commit` of the rename lands the move with the OLD
# status and citations still pointing at the vanished path — and CI is the
# first thing to see it. Hit for real in a consumer repo on 2026-09-02, where
# an entry merged as `fixed` while every local signal was green.
#
# A herestring, not a pipe, feeds grep -q here: grep -q exits the instant it
# matches, SIGPIPEing the producer, which under pipefail reads as a failed
# assertion even though the pattern was found.
git -C "$R2" diff --quiet
check "an --apply run leaves nothing unstaged" $?

grep -q '^- \*\*Status:\*\* resolved$' <<<"$(git -C "$R2" show :docs/worklog/archives/2026-08-19-1344-an-entry.md)"
check "the staged blob carries the stamped status, not the pre-close one" $?

STAGED="$(git -C "$R2" diff --cached --name-only)"
grep -q '^CLAUDE\.md$' <<<"$STAGED" \
  && grep -q '^scripts/ops/thing\.sh$' <<<"$STAGED" \
  && grep -q '^docs/notes\.md$' <<<"$STAGED"
check "every repointed citation is staged too" $?

R3="$TMP/missing"; make_repo "$R3"
( cd "$R3" && "$SCRIPT" no-such-entry --apply ) >/dev/null 2>&1
[[ $? -ne 0 ]]
check "an entry that is not open is refused" $?

# Already-archived is the likeliest mistake — a second close attempt must not
# create a second copy under a new timestamp.
( cd "$R2" && "$SCRIPT" an-entry --apply ) >/dev/null 2>&1
[[ $? -ne 0 && "$(find "$R2/docs/worklog/archives" -name '*an-entry.md' | wc -l)" -eq 1 ]]
check "closing an already-archived entry is refused, not duplicated" $?

R4="$TMP/status"; make_repo "$R4"
( cd "$R4" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry --status superseded --apply ) >/dev/null 2>&1
grep -q '^- \*\*Status:\*\* superseded$' "$R4/docs/worklog/archives/2026-08-19-1344-an-entry.md"
check "--status superseded is honoured" $?

( cd "$R4" && "$SCRIPT" an-entry --status closed --apply ) >/dev/null 2>&1
[[ $? -ne 0 ]]
check "a status the checker would reject is refused up front" $?

# `fixed` is the rung an entry wears while it waits for a human to close it, so
# archiving something as `fixed` files away an entry nobody has closed. Refusing
# here is what keeps the archive meaning "closed".
R6="$TMP/fixed"; make_repo "$R6"
( cd "$R6" && "$SCRIPT" an-entry --status fixed --apply ) > "$TMP/fixed.out" 2>&1
[[ $? -ne 0 && -f "$R6/docs/worklog/an-entry.md" ]]
check "archiving an entry as 'fixed' is refused and the entry stays put" $?

grep -qi 'until a human closes it' "$TMP/fixed.out"
check "the refusal explains where the fixed rung lives" $?

R5="$TMP/empty-resolution"; make_repo "$R5"
python3 - "$R5/docs/worklog/an-entry.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("Fixed by PR #1.", ""))
PY
git -C "$R5" commit -qam "empty resolution"
( cd "$R5" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry --apply ) > "$TMP/empty.out" 2>&1
check "an empty Resolution does not block the close" $?

grep -q "Resolution section is empty" "$TMP/empty.out"
check "an empty Resolution is warned about — the checker requires one once archived" $?

# ------------------------------------------------------------
# How a citation is spelled
# ------------------------------------------------------------
#
# An entry is cited by path, and the path depends on where the citing file
# sits: `docs/worklog/x.md` from code at the root, `worklog/x.md` from a doc
# under `docs/`, a bare `x.md` from a sibling entry, `../x.md` from one already
# archived. Matching the first spelling alone reports "0 file(s) cite this
# entry" over an entry cited from every other — and that count is what a human
# reads before deciding the move is safe.

make_spelling_repo() { # <dir>
  local d="$1"
  make_repo "$d"
  rm -f "$d/CLAUDE.md" "$d/scripts/ops/thing.sh" "$d/docs/notes.md" "$d/other.md"
  mkdir -p "$d/docs/worklog/archives" "$d/api/src"
  # One spelling per citing file, so a failure names which one broke.
  echo 'see worklog/an-entry.md'                    > "$d/docs/handbook.md"
  echo 'see an-entry.md'                            > "$d/docs/worklog/sibling.md"
  echo 'see ../an-entry.md'                         > "$d/docs/worklog/archives/2026-01-01-0000-old.md"
  # TypeScript: the extension allowlist this replaced covered .md/.sh/.py/
  # .yaml/.txt/.json, so it missed the language most repos are written in.
  echo '// see docs/worklog/an-entry.md'            > "$d/api/src/service.ts"
  # A markdown label is a NAME, not a path. Prefixing it with `archives/` turns
  # a readable label into a long path, so the label takes the new basename.
  echo '[an-entry.md](docs/worklog/an-entry.md)'    > "$d/docs/link.md"
  # Near-misses in both directions: a longer slug that ends with this one, and
  # a citation already repointed by an earlier run.
  echo 'docs/worklog/not-an-entry.md'               > "$d/docs/near-miss.md"
  echo 'docs/worklog/archives/2026-08-19-1344-an-entry.md' > "$d/docs/already.md"
  # The entry's own outbound links: one to a sibling, one to a neighbour that
  # is already archived. Both are relative to `docs/worklog/`, and the move
  # puts the entry a directory deeper.
  # ...and a mention of its own filename, which must not be repointed: the
  # entry is not a citation of itself, and the general pass would otherwise
  # rewrite the archived file to say it lives inside its own directory.
  python3 - "$d/docs/worklog/an-entry.md" <<'OWN'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "## Resolution",
    "This is `an-entry.md`. See [the sibling](sibling.md) and "
    "[the old one](archives/2026-01-01-0000-old.md).\n\n## Resolution",
))
OWN
  git -C "$d" add -A && git -C "$d" commit -qm spellings
}

R8="$TMP/spellings"; make_spelling_repo "$R8"
( cd "$R8" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 "$SCRIPT" an-entry --apply ) > "$TMP/spellings.out" 2>&1
check "an --apply run over varied citation spellings exits 0" $?

grep -q 'see worklog/archives/2026-08-19-1344-an-entry.md' "$R8/docs/handbook.md"
check "a citation written relative to docs/ keeps its prefix and gains the archive hop" $?

grep -q 'see archives/2026-08-19-1344-an-entry.md' "$R8/docs/worklog/sibling.md"
check "a bare filename cited from a sibling entry is repointed" $?

grep -q 'see ../archives/2026-08-19-1344-an-entry.md' "$R8/docs/worklog/archives/2026-01-01-0000-old.md"
check "a ../ citation from an already-archived entry is repointed" $?

grep -q '// see docs/worklog/archives/2026-08-19-1344-an-entry.md' "$R8/api/src/service.ts"
check "a citation in a source file the old extension allowlist missed is repointed" $?

[[ "$(cat "$R8/docs/link.md")" == '[2026-08-19-1344-an-entry.md](docs/worklog/archives/2026-08-19-1344-an-entry.md)' ]]
check "a markdown link's label takes the new name while its target takes the new path" $?

[[ "$(cat "$R8/docs/near-miss.md")" == 'docs/worklog/not-an-entry.md' ]]
check "a longer slug ENDING in this one is not touched" $?

[[ "$(cat "$R8/docs/already.md")" == 'docs/worklog/archives/2026-08-19-1344-an-entry.md' ]]
check "a citation already pointing into archives/ is left alone, not nested again" $?

! grep -rq 'archives/archives' "$R8" --exclude-dir=.git
check "no citation grows a second archives/ hop" $?

grep -q "5 file(s) cite this entry" "$TMP/spellings.out"
check "the count covers every spelling, and the entry does not count as citing itself" $?

# The entry's own links are relative to the directory it just left. Nothing
# else looks for these: check-worklog.sh scans for citations OF archived
# entries and never for citations FROM them.
SPELLED="$R8/docs/worklog/archives/2026-08-19-1344-an-entry.md"
grep -q '\[the sibling\](../sibling.md)' "$SPELLED"
check "a link to a still-open sibling climbs out of archives/" $?

grep -q '\[the old one\](2026-01-01-0000-old.md)' "$SPELLED"
check "a link to an already-archived neighbour drops its now-redundant hop" $?

grep -q 'This is `an-entry.md`' "$SPELLED"
check "the entry's mention of its own filename is left as written" $?

# ------------------------------------------------------------
# Files a rewrite must not touch
# ------------------------------------------------------------
#
# Some repos hold files that are checksummed once written — Prisma records a
# hash of each migration when it applies it, so editing one, even a comment,
# is drift the next `migrate deploy` reports. A repo declares those paths and
# the script leaves them alone, saying which entries cite from them so the
# stale name is a known cost rather than a surprise.

R9="$TMP/immutable"; make_repo "$R9"
mkdir -p "$R9/api/prisma/migrations/20260101_init"
echo '-- see docs/worklog/an-entry.md' > "$R9/api/prisma/migrations/20260101_init/migration.sql"
git -C "$R9" add -A && git -C "$R9" commit -qm migration
( cd "$R9" && WORKLOG_ARCHIVE_TIMESTAMP=2026-08-19-1344 WORKLOG_IMMUTABLE_PATHS=api/prisma/migrations \
    "$SCRIPT" an-entry --apply ) > "$TMP/immutable.out" 2>&1
check "an --apply run with declared immutable paths exits 0" $?

[[ "$(cat "$R9/api/prisma/migrations/20260101_init/migration.sql")" == '-- see docs/worklog/an-entry.md' ]]
check "a declared-immutable file is not rewritten" $?

grep -q 'migration.sql cites this entry' "$TMP/immutable.out"
check "the operator is told which immutable file keeps naming the old path" $?

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
