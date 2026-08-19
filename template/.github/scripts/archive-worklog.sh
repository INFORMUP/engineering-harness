#!/usr/bin/env bash
#
# Close a worklog entry: stamp its status, move it to `docs/worklog/archives/`
# under a timestamped name, and repoint every citation of it in the repo.
#
# WHY THIS IS A SCRIPT AND NOT A `git mv`. Archiving renames the file — the
# archive name carries a `YYYY-MM-DD-HHMM-` prefix so the directory sorts by
# close date — and entries are cited by path from the code they describe. The
# heavily-cited entries are exactly the ones worth archiving, so closing one by
# hand means editing every citing file correctly; getting it wrong fails the
# NEXT person's PR rather than yours, since `check-worklog.sh` rejects a
# dangling reference wherever it finds one.
#
# WHAT THIS DOES NOT COVER. Citations that cross a repo boundary. A repo that
# vendors others as submodules will name entries in their `docs/worklog/`, and
# they will name entries back. Nothing rewrites those and no checker sees them,
# so a cross-repo citation is the one half of this that still fails quietly.
# Grep the other repo by hand when archiving an entry you know it references.
#
# ONLY A HUMAN CLOSES AN ENTRY. This script is the mechanics of a decision that
# has already been made, never the decision — see `docs/worklog/CLAUDE.md`.
#
# Usage:
#   ./archive-worklog.sh <slug|path>                       # dry run
#   ./archive-worklog.sh <slug|path> --apply
#   ./archive-worklog.sh <slug|path> --status superseded --apply
#   ./archive-worklog.sh <slug|path> --next-action "…" --apply
#
set -euo pipefail

# The two ARCHIVED rungs only. `fixed` is a status an entry wears while it stays
# in the open directory — the work landed, the human has not closed it — so
# passing it here is a request to archive something nobody has closed.
readonly VALID_STATUSES="resolved superseded"

# Reads the header comment back rather than a hardcoded line range, so editing
# the prose above can never silently truncate --help.
print_help() {
    awk '/^#!/ { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

error() { echo "ERROR: $*" >&2; exit 1; }
ok()    { echo "    ok   $*"; }
info()  { echo "    ..   $*"; }
warn()  { echo "    warn $*" >&2; }

# The close timestamp, overridable so the suite can assert an exact filename.
archive_timestamp() { printf '%s' "${WORKLOG_ARCHIVE_TIMESTAMP:-$(date -u +%Y-%m-%d-%H%M)}"; }

# Accept a bare slug, a repo-relative path, or a path with a `./` on the front —
# whichever the caller happens to have in hand from a grep.
slug_from_arg() { # <slug|path>
    local arg="${1#./}"
    arg="${arg%.md}"
    arg="${arg##*/}"
    printf '%s' "$arg"
}

archive_name() { # <slug> <timestamp>
    printf '%s-%s.md' "$2" "$1"
}

# ------------------------------------------------------------------ header edits

set_status() { # <file> <status>
    local f="$1" status="$2"
    grep -qE '^- \*\*Status:\*\*' "$f" || error "$f has no '- **Status:**' bullet"
    sed -i -E "s|^- \*\*Status:\*\*.*|- **Status:** $status|" "$f"
}

# A closed entry has no next action, and leaving the one it had is the exact rot
# the worklog conventions warn about: the bottom of the entry says it landed
# while the top still says someone owes it something.
set_next_action() { # <file> <text>
    local f="$1" text="$2"
    grep -qE '^- \*\*Next action:\*\*' "$f" || return 0
    sed -i -E "s|^- \*\*Next action:\*\*.*|- **Next action:** $text|" "$f"
}

# `check-worklog.sh` requires an archived entry to carry a Resolution, but it
# cannot tell prose from a heading with nothing under it. Warn rather than
# refuse: the missing sentence is the author's to write, and blocking the move
# would just get the heading filled with the word "done".
resolution_is_empty() { # <file>
    local body
    body="$(sed -n '/^## Resolution/,$p' "$1" | tail -n +2 | sed -E 's/<!--.*-->//' | tr -d '[:space:]')"
    [[ -z "$body" ]]
}

# ------------------------------------------------------------------ citations

# Tracked text files only, and never `external/` — those are other repositories'
# checkouts, where a rewrite would show up as a dirty submodule nobody asked for.
citing_files() { # <root> <old-path>
    git -C "$1" grep -lF -e "$2" -- \
        ':!external' ':(glob)**/*.md' ':(glob)**/*.sh' ':(glob)**/*.py' \
        ':(glob)**/*.yaml' ':(glob)**/*.yml' ':(glob)**/*.txt' ':(glob)**/*.json' \
        2>/dev/null || true
}

# Reports through the global CITATION_COUNT rather than stdout: capturing this
# function's output to count it would also swallow the per-file progress lines,
# which then reappear mangled inside the summary instead of streaming as the
# rewrite happens.
CITATION_COUNT=0
rewrite_citations() { # <root> <old-path> <new-path> <apply>
    local root="$1" old="$2" new="$3" apply="$4" f n=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        n=$((n + 1))
        if [[ "$apply" == "yes" ]]; then
            # `|` as the delimiter: the paths contain `/` and no `|`. The dots
            # are escaped because sed reads the pattern as a regex, where a bare
            # `.` would also match `an-entryXmd` in some unrelated file.
            sed -i "s|${old//./\\.}|$new|g" "$root/$f"
        fi
        info "$( [[ "$apply" == "yes" ]] && echo repointed || echo "would repoint" ) $f"
    done < <(citing_files "$root" "$old")
    CITATION_COUNT="$n"
}

# ------------------------------------------------------------------ main

main() {
    local target="" status="resolved" next_action="" apply="no"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)       apply="yes"; shift ;;
            --status)      status="${2:-}"; shift 2 ;;
            --next-action) next_action="${2:-}"; shift 2 ;;
            -h|--help)     print_help; exit 0 ;;
            -*)            error "unknown argument: $1" ;;
            *)             [[ -z "$target" ]] || error "one entry at a time"; target="$1"; shift ;;
        esac
    done
    [[ -n "$target" ]] || error "usage: archive-worklog.sh <slug|path> [--apply]"
    if [[ " $VALID_STATUSES " != *" $status "* ]]; then
        [[ "$status" == "fixed" ]] && error "'fixed' is not an archive status — an entry at that rung stays in docs/worklog/ until a human closes it. Set the bullet by hand; archive when it is closed."
        error "status must be one of: $VALID_STATUSES"
    fi

    local root; root="$(git rev-parse --show-toplevel)" || error "not a git repository"
    local slug; slug="$(slug_from_arg "$target")"
    local old_rel="docs/worklog/$slug.md"
    local old_abs="$root/$old_rel"

    [[ -f "$old_abs" ]] || error "no open entry at $old_rel (already archived?)"

    local stamp new_rel
    stamp="$(archive_timestamp)"
    new_rel="docs/worklog/archives/$(archive_name "$slug" "$stamp")"

    [[ "$apply" == "yes" ]] || echo "DRY RUN — nothing is changed. Re-run with --apply."
    echo "Closing $slug:"
    info "$old_rel → $new_rel"

    if resolution_is_empty "$old_abs"; then
        warn "the Resolution section is empty — say what happened before this is archived"
    fi

    rewrite_citations "$root" "$old_rel" "$new_rel" "$apply"
    info "$CITATION_COUNT file(s) cite this entry"

    if [[ "$apply" != "yes" ]]; then
        info "would set status to '$status' and move the file"
        return 0
    fi

    set_status "$old_abs" "$status"
    set_next_action "$old_abs" "${next_action:-none — closed ${stamp%-*}}"
    mkdir -p "$root/docs/worklog/archives"
    git -C "$root" mv "$old_rel" "$new_rel"
    ok "archived as $new_rel, status $status, $CITATION_COUNT citation(s) repointed"

    # The checker is the backstop for everything this script does not know about
    # — a dangling reference in a file type not rewritten above, a required
    # section the entry never had.
    if [[ -x "$root/.github/scripts/check-worklog.sh" ]]; then
        "$root/.github/scripts/check-worklog.sh"
    fi
}

if [[ "${ARCHIVE_WORKLOG_SOURCE_ONLY:-}" != "1" ]]; then
    main "$@"
fi
