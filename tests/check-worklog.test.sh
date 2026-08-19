#!/usr/bin/env bash
# Self-test for template/.github/scripts/check-worklog.sh
# Tests for .github/scripts/check-worklog.sh.
# Run: ./scripts/ops/check-worklog.test.sh
#
# Hermetic: every case builds a throwaway worklog directory under a temp dir and
# points the checker at it with --dir, so the repo's real entries are never read
# and no assertion here depends on their current contents.
#
# Deliberately NOT `set -e`: we want every assertion to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../template/.github/scripts/check-worklog.sh"
TMP="$(mktemp -d /tmp/check-worklog-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

# A conforming entry, parameterized so each case can break exactly one thing.
# $1 dir  $2 filename  $3 title  $4 status  [$5 extra body appended]
write_entry() {
  local dir=$1 name=$2 title=$3 status=$4 extra=${5:-}
  mkdir -p "$dir"
  cat > "$dir/$name" <<ENTRY
# $title

- **Status:** $status
- **Found:** 2026-08-14, while doing the thing that surfaced it
- **Escalated:** no
- **Next action:** none — parked

## Observation

The system does the wrong thing.

## Evidence

\`\`\`
\$ some command
some output
\`\`\`

## Why it matters

Because of the consequence.

## Approaches considered

- **Do nothing** — rejected (agent-derived), because reasons.

---

## Resolution

<!-- Appended when it lands. -->
$extra
ENTRY
}

new_dir() { # <name> -> path to a fresh worklog dir holding one clean entry
  local d="$TMP/$1"
  mkdir -p "$d/archives"
  write_entry "$d" "widget-fails-on-restart.md" "The widget fails on restart" "open"
  echo "$d"
}

run() { # <args...>  -> rc in $rc, stdout+stderr in $TMP/out
  "$SCRIPT" "$@" >"$TMP/out" 2>&1
  rc=$?
}

# ------------------------------------------------------------------ clean corpus
D="$(new_dir clean)"
run --dir "$D"
check "conforming entry: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

# CLAUDE.md and the template are conventions, not entries, and must be skipped.
echo "# not an entry" > "$D/CLAUDE.md"
printf '# <title>\n\nno header block here\n' > "$D/0000-template.md"
run --dir "$D"
check "CLAUDE.md and 0000-template.md are not checked as entries" "$([[ $rc -eq 0 ]]; echo $?)"

# ------------------------------------------------------------------ header shape
D="$(new_dir noheader)"
cat > "$D/widget-fails-on-restart.md" <<'EOF'
# The widget fails on restart

Status: **open**

## Observation
x
## Evidence
x
## Why it matters
x
## Approaches considered
x

---

## Resolution
x
EOF
run --dir "$D"
check "status not in the template bullet form: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -qi 'status' "$TMP/out"
check "status-shape finding names the field" $?
grep -q 'widget-fails-on-restart.md' "$TMP/out"
check "finding names the offending file" $?

D="$(new_dir nofound)"
sed -i '/\*\*Found:\*\*/d' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "missing Found: bullet: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir badfound)"
sed -i 's/\*\*Found:\*\* 2026-08-14/**Found:** last Tuesday/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "Found: without a YYYY-MM-DD date: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir noescalated)"
sed -i '/\*\*Escalated:\*\*/d' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "missing Escalated: bullet: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

# --------------------------------------------------------------- status vocabulary
D="$(new_dir prosestatus)"
sed -i 's/\*\*Status:\*\* open/**Status:** open — three of four rotated, the fourth is undecided/' \
  "$D/widget-fails-on-restart.md"
run --dir "$D"
check "prose qualifier in the status slot: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -qi 'next action' "$TMP/out"
check "prose-status finding points at the Next action line" $?

D="$(new_dir trailingcomment)"
sed -i 's/\*\*Status:\*\* open/**Status:** open <!-- open | resolved | superseded -->/' \
  "$D/widget-fails-on-restart.md"
run --dir "$D"
check "trailing HTML comment after the status word is allowed" "$([[ $rc -eq 0 ]]; echo $?)"

# The middle rung: the work landed, the human has not closed it. It lives in the
# OPEN directory — an entry nobody has closed is not archived — so both halves of
# the placement rule have to accept it, and the pair is what usually disagrees.
D="$(new_dir fixedopen)"
sed -i 's/\*\*Status:\*\* open/**Status:** fixed/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "fixed in the open directory is allowed" "$([[ $rc -eq 0 ]]; echo $?)"

# `fixed` is not a close. If it reaches archives/ the entry has been filed away
# while still owing someone the decision to close it — the thing the rung exists
# to make visible.
D="$(new_dir fixedarchived)"
mkdir -p "$D/archives"
sed 's/\*\*Status:\*\* open/**Status:** fixed/' "$D/widget-fails-on-restart.md" \
  > "$D/archives/2026-08-19-1200-widget-fails-on-restart.md"
rm "$D/widget-fails-on-restart.md"
run --dir "$D"
check "fixed in archives/: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

# The qualifier advice must reach the new rung too — "fixed, awaiting close" is
# the single most likely thing anyone types into that slot, and it is exactly
# what the bare word now replaces.
D="$(new_dir fixedqualified)"
sed -i 's/\*\*Status:\*\* open/**Status:** fixed, awaiting close/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "qualified 'fixed, awaiting close': exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -qi 'next action' "$TMP/out"
check "the qualified-fixed finding points at the Next action line" $?

D="$(new_dir unknownstatus)"
sed -i 's/\*\*Status:\*\* open/**Status:** wontfix/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "status outside the vocabulary: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

# ------------------------------------------------------------- archive placement
D="$(new_dir resolvednotarchived)"
sed -i 's/\*\*Status:\*\* open/**Status:** resolved/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "resolved entry left outside archives/: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -q 'archives/' "$TMP/out"
check "placement finding names archives/" $?

D="$(new_dir supersedednotarchived)"
sed -i 's/\*\*Status:\*\* open/**Status:** superseded/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "superseded entry left outside archives/: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir openinarchives)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D/archives" "2026-08-01-1200-widget-fails-on-restart.md" \
  "The widget fails on restart" "open"
run --dir "$D"
check "open entry sitting in archives/: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir archivedok)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D/archives" "2026-08-01-1200-widget-fails-on-restart.md" \
  "The widget fails on restart" "resolved"
run --dir "$D"
check "resolved entry correctly archived with a timestamp prefix: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir archivenoprefix)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D/archives" "widget-fails-on-restart.md" "The widget fails on restart" "resolved"
run --dir "$D"
check "archived file without the YYYY-MM-DD-HHMM- prefix: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

# ------------------------------------------------------------- required sections
for section in "Observation" "Evidence" "Why it matters"; do
  slug="$(echo "$section" | tr ' A-Z' '-a-z')"
  D="$(new_dir "missing$slug")"
  sed -i "/^## $section\$/d" "$D/widget-fails-on-restart.md"
  run --dir "$D"
  check "missing '## $section' section: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
done

# Not every entry is an issue — an entry recording an executed change weighed no
# alternatives, and an empty heading is worse than an absent one.
D="$(new_dir noapproaches)"
sed -i '/^## Approaches considered$/,+2d' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "missing '## Approaches considered' is allowed" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir noresolutionopen)"
sed -i '/^## Resolution$/,+2d' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "an OPEN entry with no '## Resolution' is allowed" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir noresolutionarchived)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D/archives" "2026-08-01-1200-widget-fails-on-restart.md" \
  "The widget fails on restart" "resolved"
sed -i '/^## Resolution$/,+2d' "$D/archives/2026-08-01-1200-widget-fails-on-restart.md"
run --dir "$D"
check "an ARCHIVED entry with no '## Resolution': exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir extrasections)"
sed -i 's/^## Why it matters$/## Who the second client is\n\nsomebody\n\n## Why it matters/' \
  "$D/widget-fails-on-restart.md"
run --dir "$D"
check "extra sections beyond the required five are allowed" "$([[ $rc -eq 0 ]]; echo $?)"

# ------------------------------------------------------------- filename vs title
D="$(new_dir slugdrift)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D" "cdn-origin-discrepancy.md" \
  "Attaching media to a social post is broken in production" "open"
run --dir "$D"
check "filename slug sharing no word with the title: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -qi 'git mv' "$TMP/out"
check "slug-drift finding suggests the rename" $?

D="$(new_dir slugok)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D" "social-post-media-broken-in-prod.md" \
  "Attaching media to a social post is broken in production" "open"
run --dir "$D"
check "filename slug sharing a substantive word with the title: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

# Stopwords must not count as agreement, or every filename passes.
D="$(new_dir slugstopwords)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D" "the-and-with-from-that.md" \
  "Attaching media to a social post is broken in production" "open"
run --dir "$D"
check "agreement on stopwords alone does not count: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

# ---------------------------------------------------------------- head/log split
D="$(new_dir lognorule)"
rm "$D/widget-fails-on-restart.md"
write_entry "$D" "widget-fails-on-restart.md" "The widget fails on restart" "open"
# Strip the rule, then add a Log section: appends with no head/log boundary.
sed -i '/^---$/d' "$D/widget-fails-on-restart.md"
printf '\n## Log\n\n### 2026-08-15 — something changed\n\nx\n' >> "$D/widget-fails-on-restart.md"
run --dir "$D"
check "## Log with no --- rule above it: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"

D="$(new_dir logwithrule)"
printf '\n## Log\n\n### 2026-08-15 — something changed\n\nx\n' >> "$D/widget-fails-on-restart.md"
run --dir "$D"
check "## Log below the --- rule: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

# ------------------------------------------------------------------ reporting
D="$(new_dir multi)"
write_entry "$D" "second-entry-here.md" "The second entry here" "wontfix"
sed -i 's/\*\*Status:\*\* open/**Status:** alsobad/' "$D/widget-fails-on-restart.md"
run --dir "$D"
check "two broken entries: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
[[ $(grep -c 'widget-fails-on-restart.md' "$TMP/out") -ge 1 && \
   $(grep -c 'second-entry-here.md' "$TMP/out") -ge 1 ]]
check "every offending file is reported, not just the first" $?

run --dir "$D" --list
check "--list exits 0 even with violations present" "$([[ $rc -eq 0 ]]; echo $?)"
grep -q 'widget-fails-on-restart' "$TMP/out"
check "--list prints each entry" $?

# ----------------------------------------------------------------------- usage
run --dir "$D" --bogus-flag
check "unknown flag: exit 2" "$([[ $rc -eq 2 ]]; echo $?)"

run --dir "$TMP/does-not-exist"
check "missing --dir target: exit 2" "$([[ $rc -eq 2 ]]; echo $?)"

run --help
check "--help: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

# ------------------------------------------------------- filename/title agreement
# The heuristic behind the "filename shares no word with the title" finding. It
# leans generous on purpose: a missed agreement is a finding the repo can only
# clear by renaming a file other files cite by path.
D="$(new_dir slugs)"
write_entry "$D" "api-tests-ci-duration.md" \
  'The `api-tests` CI job takes ~10 minutes, and most of it is rebuilding the app' "open"
run --dir "$D"
check "a title's backticked identifier still counts as a word" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir slugs-inflect)"
write_entry "$D" "orphan-refs-on-delete.md" \
  "Deleting a survey leaves its article reference behind, and nothing notices" "open"
run --dir "$D"
check "delete/deleting agree — a shared stem, not a shared prefix" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir slugs-contain)"
write_entry "$D" "source-pg-tls-unverified.md" \
  "The connection to a legacy Postgres is encrypted but not certificate-verified" "open"
run --dir "$D"
check "unverified/verified agree — the shorter is contained in the longer" "$([[ $rc -eq 0 ]]; echo $?)"

D="$(new_dir slugs-drifted)"
write_entry "$D" "widget-fails-on-restart.md" \
  "Invoices are emailed twice whenever a payment retries" "open"
run --dir "$D"
check "a slug sharing genuinely nothing with the title is still a finding" "$([[ $rc -eq 1 ]]; echo $?)"

# ------------------------------------------------------------ dangling references
# Archiving renames the entry; anything citing the old path goes quietly dangling.
# Needs a real git repo laid out like this one, since the scan is repo-root-relative.
mk_repo() { # <name> -> repo root holding docs/worklog + scripts
  local root="$TMP/$1"
  mkdir -p "$root/docs/worklog/archives" "$root/scripts"
  git -c init.defaultBranch=main init -q "$root"
  write_entry "$root/docs/worklog" "widget-fails-on-restart.md" \
    "The widget fails on restart" "open"
  echo "# repo" > "$root/CLAUDE.md"
  echo "$root"
}

# The scan reads TRACKED files, the same pathspec `archive-worklog.sh` rewrites —
# so staging is part of the fixture, not incidental setup. The two must agree:
# a checker that flagged files the archiver cannot repoint would leave a PR red
# with no correct way to make it green.
stage() { git -C "$1" add -A; }

R="$(mk_repo refsok)"
echo "# see docs/worklog/widget-fails-on-restart.md" > "$R/scripts/thing.sh"
stage "$R"
run --dir "$R/docs/worklog"
check "reference to an entry that exists: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

R="$(mk_repo refsdangling)"
echo "# see docs/worklog/widget-fails-on-restart.md" > "$R/scripts/thing.sh"
mv "$R/docs/worklog/widget-fails-on-restart.md" \
   "$R/docs/worklog/archives/2026-08-01-1200-widget-fails-on-restart.md"
sed -i 's/\*\*Status:\*\* open/**Status:** resolved/' \
   "$R/docs/worklog/archives/2026-08-01-1200-widget-fails-on-restart.md"
stage "$R"
run --dir "$R/docs/worklog"
check "archiving without fixing an inbound reference: exit 1" "$([[ $rc -eq 1 ]]; echo $?)"
grep -q 'dangling reference' "$TMP/out"
check "dangling-reference finding says so" $?
grep -q 'scripts/thing.sh' "$TMP/out"
check "dangling-reference finding names the citing file" $?

# A citation inside `external/` belongs to another repository's checkout: this
# repo can neither rewrite it nor be held responsible for it, so both scripts
# skip that path and the checker must not flag it.
R="$(mk_repo refsexternal)"
mkdir -p "$R/external/other/docs"
echo "# see docs/worklog/widget-fails-on-restart.md" > "$R/external/other/docs/notes.md"
mv "$R/docs/worklog/widget-fails-on-restart.md" \
   "$R/docs/worklog/archives/2026-08-01-1200-widget-fails-on-restart.md"
sed -i 's/\*\*Status:\*\* open/**Status:** resolved/' \
   "$R/docs/worklog/archives/2026-08-01-1200-widget-fails-on-restart.md"
stage "$R"
run --dir "$R/docs/worklog"
check "a citation under external/ is not a dangling reference: exit 0" "$([[ $rc -eq 0 ]]; echo $?)"

# --------------------------------------------------------- the repo's own entries
# The point of the gate: this must stay green as entries are added. The harness
# itself keeps no worklog, so this is a no-op here and live in every consumer.
REPO_WORKLOG="$HERE/../docs/worklog"
if [[ -d "$REPO_WORKLOG" ]]; then
  run --dir "$REPO_WORKLOG"
  check "the repo's own docs/worklog/ passes" "$([[ $rc -eq 0 ]]; echo $?)"
fi

echo
echo "tests: $((pass+fail))  pass: $pass  fail: $fail"
[[ $fail -eq 0 ]]
