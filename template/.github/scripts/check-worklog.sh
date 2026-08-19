#!/usr/bin/env bash
#
# check-worklog.sh — is every worklog entry still saying what it means to say?
#
# The worklog's failure mode is not that entries go unwritten; it is that they rot
# quietly. An entry gets updated by appending, and the status line — the field
# furthest from wherever the update was typed — keeps its old value. Auditing a
# real 50-entry worklog by hand turned up a file sitting in archives/ still marked
# `open`, two entries marked `resolved` that were never moved there, a status slot
# holding a paragraph instead of a state, five entries with no header block at all,
# and a filename that had not followed its own subject when the investigation
# moved. A 170-entry one turned up the same five kinds, 217 times.
#
# Every one of those is mechanically detectable, which is what this script is for.
# The half that is NOT detectable — keeping the head of the entry true when the log
# below it grows — is documented in docs/worklog/CLAUDE.md and is on the writer.
#
#   .github/scripts/check-worklog.sh [--dir <path>] [--list] [-h|--help]
#
# --list prints every entry's state as a table and always exits 0; use it to see the
# open/resolved population rather than to gate on it.
#
# Exit codes: 0 clean, 1 one or more findings, 2 usage error.
set -uo pipefail

info() { echo -e "\033[1;34m  ·\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
bad()  { echo -e "\033[1;31m  ✗\033[0m $*"; }

print_help() {
  awk '
    /^#!/       { next }
    /^set -uo/  { exit }
    { sub(/^# ?/, ""); print }
  ' "${BASH_SOURCE[0]}"
}

usage_error() {
  echo "Usage: $0 [--dir <path>] [--list] [-h|--help]" >&2
  exit 2
}

DIR=""
LIST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     [[ $# -ge 2 ]] || usage_error; DIR="$2"; shift 2 ;;
    --list)    LIST=true; shift ;;
    -h|--help) print_help; exit 0 ;;
    *)         usage_error ;;
  esac
done

if [[ -z "$DIR" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository" >&2; exit 2; }
  DIR="$ROOT/docs/worklog"
fi
[[ -d "$DIR" ]] || { echo "no such directory: $DIR" >&2; exit 2; }

# Four rungs, and the middle one is load-bearing: `fixed` means the work landed
# and only a human close remains. Without it, "open" means two different things
# and the directory can no longer answer the one question it exists to answer —
# what still owes someone work. `fixed` lives in the OPEN directory, like `open`;
# only `resolved` and `superseded` are archived states. Only Max moves an entry
# off `fixed` (docs/worklog/CLAUDE.md).
readonly VALID_STATUSES="open fixed resolved superseded"
readonly ARCHIVED_STATUSES="resolved superseded"
# Only sections every entry genuinely has. Not every entry is an issue — some
# record an executed change — and those have no alternatives that were weighed, so
# requiring "Approaches considered" everywhere would buy conformance in empty
# headings. It stays expected-but-unenforced (docs/worklog/CLAUDE.md); an empty
# section is worse than an absent one. Resolution is required only once the entry
# is archived, checked below, since an open entry has nothing to put there.
readonly REQUIRED_SECTIONS=("Observation" "Evidence" "Why it matters")
readonly ARCHIVE_PREFIX_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-'
# Words that carry no subject, so agreement on them says nothing about whether a
# filename still describes its entry.
readonly SLUG_STOPWORDS=" the a an and or but for from with into onto out off is are was were be been \
being not no its it this that these those of in on at to by as has have had does do did can cannot \
will would should must more most one two all any own via per than then when where which who whom "

# ------------------------------------------------------------------ field readers
# The header block is the first few lines; a `- **Field:** value` bullet, one per
# line. Anything else — a bare `Status: open`, a bolded line, no block at all — is
# a finding, because a field that cannot be parsed cannot be checked.
header_field() { # <file> <field> -> value with any trailing HTML comment stripped
  sed -n "1,15p" "$1" \
    | grep -m1 -E "^- \*\*$2:\*\*" \
    | sed -E "s/^- \*\*$2:\*\*[[:space:]]*//; s/<!--.*//" \
    | sed -E 's/[[:space:]]+$//'
}

entry_title() { # <file>
  sed -n '1s/^# *//p' "$1"
}

# Split a filename slug or a title into comparable lowercase word tokens. The
# backticks are dropped and their CONTENTS kept: a title's code spans name the
# very identifiers a slug tends to be built from, so discarding them made
# `api-tests-ci-duration.md` share no word with "The `api-tests` CI job takes ~10
# minutes" — a finding with nothing wrong behind it.
tokens() { # <text>
  echo "$1" \
    | tr 'A-Z' 'a-z' \
    | sed -E 's/[^a-z0-9]+/ /g' \
    | tr ' ' '\n' \
    | grep -vE '^$'
}

is_stopword() { [[ "$SLUG_STOPWORDS" == *" $1 "* ]]; }

# Two tokens agree if the shorter is contained in the longer, or if they share a
# long enough prefix. Containment covers run/runs and verified/unverified;
# the prefix arm covers inflections that containment misses, delete/deleting
# being the one that motivated it.
#
# Both arms are deliberately generous, because the two errors are not
# symmetrical. A missed agreement is a finding the repo cannot clear without
# renaming a file that other files cite by path — the expensive direction. A
# spurious agreement only costs a slug that drifted going unnoticed, which is
# what this heuristic was always going to miss some of. So when in doubt, agree.
readonly TOKEN_CONTAIN_MIN=4
readonly TOKEN_PREFIX_MIN=5
tokens_agree() { # <a> <b>
  local a=$1 b=$2 short long i
  if [[ ${#a} -le ${#b} ]]; then short=$a; long=$b; else short=$b; long=$a; fi
  [[ ${#short} -ge $TOKEN_CONTAIN_MIN && "$long" == *"$short"* ]] && return 0
  for ((i = ${#short}; i >= TOKEN_PREFIX_MIN; i--)); do
    [[ "${long:0:i}" == "${short:0:i}" ]] && return 0
  done
  return 1
}

# ------------------------------------------------------------------------ checks
findings=0
files_with_findings=0

finding() { # <file> <message>
  bad "$(basename "$1"): $2"
  findings=$((findings+1))
  file_findings=$((file_findings+1))
}

check_entry() { # <path> <is_archived>
  local f=$1 archived=$2 base status found escalated title
  file_findings=0
  base="$(basename "$f")"
  title="$(entry_title "$f")"

  [[ -n "$title" ]] || finding "$f" "no '# title' heading on the first line"

  # --- header block -------------------------------------------------------
  status="$(header_field "$f" Status)"
  found="$(header_field "$f" Found)"
  escalated="$(header_field "$f" Escalated)"

  if [[ -z "$status" ]]; then
    finding "$f" "no '- **Status:** …' bullet in the header block (see 0000-template.md)"
  elif [[ " $VALID_STATUSES " != *" $status "* ]]; then
    if [[ "$status" == open* || "$status" == fixed* || "$status" == resolved* || "$status" == superseded* ]]; then
      finding "$f" "status carries a qualifier: '${status:0:60}…' — the slot holds one bare word; put the rest on a '- **Next action:**' line"
    else
      finding "$f" "status '$status' is not one of: $VALID_STATUSES"
    fi
  fi

  [[ -n "$escalated" ]] || finding "$f" "no '- **Escalated:** …' bullet (write 'no' when it is not tracked)"

  if [[ -z "$found" ]]; then
    finding "$f" "no '- **Found:** …' bullet"
  elif [[ ! "$found" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    finding "$f" "found date does not start with YYYY-MM-DD: '${found:0:40}'"
  fi

  # --- placement ----------------------------------------------------------
  # Status and location are two records of the same fact, so they are the pair
  # most likely to disagree — which is exactly why they are worth checking.
  if $archived; then
    [[ " $ARCHIVED_STATUSES " != *" $status "* && -n "$status" ]] && \
      finding "$f" "sits in archives/ but is marked $status — an archived entry is resolved or superseded; set it in the same commit that archives the file"
    [[ "$base" =~ $ARCHIVE_PREFIX_RE ]] || \
      finding "$f" "archived without a YYYY-MM-DD-HHMM- completion prefix"
    grep -qxF "## Resolution" "$f" || \
      finding "$f" "archived with no '## Resolution' section — record the PR, or the decision not to act"
  else
    [[ " $ARCHIVED_STATUSES " == *" $status "* ]] && \
      finding "$f" "marked $status but still in the open directory — move it to archives/ with a YYYY-MM-DD-HHMM- prefix (.github/scripts/archive-worklog.sh does this)"
  fi

  # --- required sections --------------------------------------------------
  local section
  for section in "${REQUIRED_SECTIONS[@]}"; do
    grep -qxF "## $section" "$f" || \
      finding "$f" "no '## $section' section (extra sections are fine; this one is not optional)"
  done

  # --- head/log split -----------------------------------------------------
  # Appends belong below a `---` rule, so the head above it can be read as
  # current. A Log with no rule above it means the two have merged.
  if grep -qxF "## Log" "$f"; then
    local log_line rule_line
    log_line="$(grep -nxF "## Log" "$f" | head -1 | cut -d: -f1)"
    rule_line="$(grep -nx -- "---" "$f" | head -1 | cut -d: -f1)"
    if [[ -z "$rule_line" || "$rule_line" -gt "$log_line" ]]; then
      finding "$f" "has a '## Log' with no '---' rule above it — the append-only half must be fenced off from the head"
    fi
  fi

  # --- filename still describes the entry ---------------------------------
  local slug slug_tokens title_tokens t u agreed=false substantive=false
  slug="${base%.md}"
  slug="$(echo "$slug" | sed -E "s/$ARCHIVE_PREFIX_RE//")"
  mapfile -t slug_tokens < <(tokens "$slug")
  mapfile -t title_tokens < <(tokens "$title")
  for t in "${slug_tokens[@]:-}"; do
    [[ -n "$t" ]] || continue
    is_stopword "$t" && continue
    substantive=true
    for u in "${title_tokens[@]:-}"; do
      is_stopword "$u" && continue
      if tokens_agree "$t" "$u"; then agreed=true; break 2; fi
    done
  done
  if [[ -n "$title" ]] && ! $agreed; then
    if $substantive; then
      finding "$f" "filename shares no word with the title — the subject moved and the name did not; \`git mv\` it and fix inbound links"
    else
      finding "$f" "filename is all stopwords — name it for the issue; \`git mv\` it and fix inbound links"
    fi
  fi

  [[ $file_findings -gt 0 ]] && files_with_findings=$((files_with_findings+1))
  return 0
}

# --------------------------------------------------------------------- collect
mapfile -t OPEN_ENTRIES < <(find "$DIR" -maxdepth 1 -name '*.md' \
  ! -name 'CLAUDE.md' ! -name '0000-template.md' | sort)
mapfile -t ARCHIVED_ENTRIES < <(find "$DIR/archives" -maxdepth 1 -name '*.md' \
  ! -name 'CLAUDE.md' 2>/dev/null | sort)

if $LIST; then
  printf '%-58s  %-11s  %s\n' "ENTRY" "STATUS" "FOUND"
  for f in "${OPEN_ENTRIES[@]:-}" "${ARCHIVED_ENTRIES[@]:-}"; do
    [[ -n "$f" ]] || continue
    printf '%-58s  %-11s  %s\n' \
      "$(basename "$f")" \
      "$(header_field "$f" Status | cut -c1-11)" \
      "$(header_field "$f" Found | cut -c1-10)"
  done
  echo
  echo "${#OPEN_ENTRIES[@]} open, ${#ARCHIVED_ENTRIES[@]} archived"
  exit 0
fi

for f in "${OPEN_ENTRIES[@]:-}";     do [[ -n "$f" ]] && check_entry "$f" false; done
for f in "${ARCHIVED_ENTRIES[@]:-}"; do [[ -n "$f" ]] && check_entry "$f" true;  done

# ----------------------------------------------------------- dangling references
# Archiving renames the file — `foo.md` becomes `archives/2026-08-10-1921-foo.md` —
# and every doc and script that cited the old path silently goes dangling. That is
# the archive convention's actual failure mode rather than a hypothetical one:
# entries are cited by path from the code they describe, and the heavily-cited ones
# are exactly the ones that get archived. `archive-worklog.sh` repoints citations
# as it moves a file; this is the backstop for a hand-move and for file types that
# script does not rewrite. Only runs when pointed at a real repo's worklog: a --dir
# under a temp path has no repo to scan.
REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$REPO_ROOT" && "$(cd "$DIR" && pwd)" == "$REPO_ROOT/docs/worklog" ]]; then
  # Checked in the reverse direction — for each archived entry, is anything still
  # citing its pre-archive path? Scanning every `docs/worklog/*.md` reference
  # forward would flag legitimate ones, because an entry about a vendored repo
  # lives in THAT repo's docs/worklog/ and is cited here by the same relative
  # path. Going backwards from what was actually renamed has no such ambiguity.
  #
  # Tracked files only, and never `external/` — those are other repositories'
  # checkouts, whose citations this repo neither owns nor can repoint. Same
  # pathspec as `archive-worklog.sh`'s, deliberately: the checker must flag
  # exactly the set the archiver rewrites, or closing an entry correctly still
  # leaves the next PR red.
  for f in "${ARCHIVED_ENTRIES[@]:-}"; do
    [[ -n "$f" ]] || continue
    stale="docs/worklog/$(basename "$f" | sed -E "s/$ARCHIVE_PREFIX_RE//")"
    citers="$(git -C "$REPO_ROOT" grep -lF -e "$stale" -- \
      ':!external' ':(glob)**/*.md' ':(glob)**/*.sh' ':(glob)**/*.py' \
      ':(glob)**/*.yaml' ':(glob)**/*.yml' ':(glob)**/*.txt' ':(glob)**/*.json' \
      2>/dev/null | paste -sd' ' -)"
    [[ -n "$citers" ]] || continue
    bad "dangling reference to $stale — that entry is archived; cited by: $citers"
    findings=$((findings+1))
  done
fi

total=$(( ${#OPEN_ENTRIES[@]} + ${#ARCHIVED_ENTRIES[@]} ))
echo
if [[ $findings -eq 0 ]]; then
  ok "$total worklog entries, no findings"
  exit 0
fi
bad "$findings finding(s) across $files_with_findings of $total entries"
info "conventions: docs/worklog/CLAUDE.md — template: docs/worklog/0000-template.md"
exit 1
