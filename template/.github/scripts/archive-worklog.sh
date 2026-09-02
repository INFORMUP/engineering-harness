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

# Replaces one header bullet — the whole field, not its first line. A bullet's
# value wraps onto indented continuation lines whenever the prose is longer than
# the width, and a line-anchored rewrite leaves those behind welded onto the
# replacement. The stranded half is always the stale one, so the failure is an
# archived entry whose header asserts, in the present tense, that the closed
# thing is still owed something — and `check-worklog.sh` cannot see it, because
# the first line is still a well-formed bullet.
#
# The field ends at the next bullet, a blank line, or a heading; anything
# indented before that belongs to it.
set_header_field() { # <file> <label> <text>
    local f="$1" label="$2"
    local tmp="$f.tmp.$$"
    HEADER_FIELD_TEXT="$3" awk -v label="$label" '
        BEGIN { text = ENVIRON["HEADER_FIELD_TEXT"]; replaced = 0; dropping = 0 }
        !replaced && $0 ~ "^- \\*\\*" label ":\\*\\*" {
            print "- **" label ":** " text
            replaced = 1; dropping = 1
            next
        }
        dropping {
            if ($0 ~ /^[[:space:]]+[^[:space:]]/) next
            dropping = 0
        }
        { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

set_status() { # <file> <status>
    local f="$1" status="$2"
    grep -qE '^- \*\*Status:\*\*' "$f" || error "$f has no '- **Status:**' bullet"
    set_header_field "$f" 'Status' "$status"
}

# A closed entry has no next action, and leaving the one it had is the exact rot
# the worklog conventions warn about: the bottom of the entry says it landed
# while the top still says someone owes it something.
set_next_action() { # <file> <text>
    local f="$1" text="$2"
    grep -qE '^- \*\*Next action:\*\*' "$f" || return 0
    set_header_field "$f" 'Next action' "$text"
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

# WHAT COUNTS AS A CITATION. Entries are cited by path, and the path is spelled
# differently depending on where the citing file sits: `docs/worklog/x.md` from
# code at the root, `worklog/x.md` from a doc under `docs/`, a bare `x.md` from
# a sibling entry, `../x.md` from one already archived. Matching only the first
# of those makes this report "0 file(s) cite this entry" over an entry cited
# from every other spelling — and that count is what a human reads before
# deciding the move is safe.
#
# So the match is the FILENAME, anchored two ways. The leading lookbehind keeps
# `not-the-thing.md` out of `the-thing`'s rewrite and, because the archive
# prefix ends in `-`, also keeps an already-archived path from matching itself.
# The second keeps `archives/x.md` out, so re-running over a repointed citation
# is a no-op rather than a nested path.
citation_re() { # <slug>
    printf '(?<![A-Za-z0-9_-])(?<!archives/)%s\\.md' "$1"
}

# Paths this script must not write to, space-separated, declared by the repo.
# The case this exists for is a file that is checksummed once written: Prisma
# records a hash of each migration when it applies it, so editing one — even a
# comment — is drift the next `migrate deploy` reports. Most repos have none,
# which is why the default is empty; a repo that does sets it here in its own
# copy (`api/prisma/migrations` is the worked example), and the environment
# override exists for the test suite. Such a citation is not silently skipped:
# the operator is told which file keeps naming the pre-archive filename, so the
# stale name is a known cost rather than a surprise.
readonly IMMUTABLE_PATHS="${WORKLOG_IMMUTABLE_PATHS:-}"

# Turns that declaration into git pathspecs — exclusions for the rewrite scan,
# and the bare paths for the report of what was left alone.
immutable_pathspecs() { # <prefix: ! or empty>
    local p
    for p in $IMMUTABLE_PATHS; do printf ':%s%s\n' "$1" "$p"; done
}

# Every tracked TEXT file, not an extension allowlist. The allowlist this
# replaced covered .md/.sh/.py/.yaml/.txt/.json and therefore missed the
# language most repos are actually written in — most citations of a
# code-adjacent entry live in the code that entry describes. `-I` drops
# binaries; `external/` is other repositories' checkouts, where a rewrite would
# surface as a dirty submodule nobody asked for; and the entry excludes itself,
# since its own links are relocated rather than repointed (below).
citing_files() { # <root> <slug> <self-path>
    local -a excludes=(':!external' ":!$3")
    mapfile -t -O "${#excludes[@]}" excludes < <(immutable_pathspecs '!')
    git -C "$1" grep -lIP -e "$(citation_re "$2")" -- "${excludes[@]}" 2>/dev/null || true
}

# The citations this script deliberately will not touch, so it can say so.
frozen_citing_files() { # <root> <slug>
    local -a included
    mapfile -t included < <(immutable_pathspecs '')
    [[ "${#included[@]}" -gt 0 ]] || return 0
    git -C "$1" grep -lIP -e "$(citation_re "$2")" -- "${included[@]}" 2>/dev/null || true
}

# Reports through the global CITATION_COUNT rather than stdout: capturing this
# function's output to count it would also swallow the per-file progress lines,
# which then reappear mangled inside the summary instead of streaming as the
# rewrite happens.
CITATION_COUNT=0
rewrite_citations() { # <root> <slug> <self-path> <new-basename> <apply>
    local root="$1" slug="$2" self="$3" new="$4" apply="$5" f n=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        n=$((n + 1))
        if [[ "$apply" == "yes" ]]; then
            # Perl, not sed: the anchors above are lookbehinds, which sed has
            # no form of. Both operands travel in the environment, so neither a
            # slug nor a path is ever spliced into the program text.
            #
            # Two passes, and the order matters. A citation is sometimes a NAME
            # rather than a path — a markdown link whose label is the filename,
            # a backticked mention in prose — and prefixing those with
            # `archives/` turns a readable label into a long path. Those take
            # the new basename; the general pass then repaths what is left,
            # which is the actual link targets and code comments.
            WL_SLUG="$slug" WL_BASE="$new" WL_NEW="archives/$new" perl -pi -e '
                BEGIN { $s = quotemeta $ENV{WL_SLUG}; $b = $ENV{WL_BASE}; $n = $ENV{WL_NEW} }
                s{(?<![A-Za-z0-9_-])(?<!archives/)(?<=[\[`])$s\.md}{$b}g;
                s{(?<![A-Za-z0-9_-])(?<!archives/)$s\.md}{$n}g;
            ' "$root/$f"
            # Stage it in the same breath. An unstaged rewrite is worse than no
            # rewrite: the rename below IS staged, so a plain `git commit` lands
            # the move with every citation still pointing at the vanished path —
            # precisely the dangling-reference breakage this function exists to
            # prevent, and it fails the NEXT person's PR rather than this one.
            git -C "$root" add -- "$f"
        fi
        info "$( [[ "$apply" == "yes" ]] && echo repointed || echo "would repoint" ) $f"
    done < <(citing_files "$root" "$slug" "$self")
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        warn "$f cites this entry and is declared immutable — left alone, so it keeps naming the pre-archive filename"
    done < <(frozen_citing_files "$root" "$slug")
    CITATION_COUNT="$n"
}

# An archived entry's OWN links are relative to `docs/worklog/`, and the move
# puts it a directory deeper. A link to a sibling then resolves inside
# `archives/` and points at nothing, and a link to an already-archived entry
# grows a second `archives/` hop. Neither is visible to `check-worklog.sh`,
# which looks for citations OF archived entries and never for citations FROM
# them — so this half goes unnoticed far longer than the inbound one.
#
# Markdown link targets only. A backticked filename in prose is a name, not a
# path, and rewriting it would say the file moved when what moved is the reader.
relocate_own_links() { # <file>
    perl -pi -e '
        # An already-archived neighbour is now a sibling: drop the hop.
        s{\]\(archives/([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[^)]+\.md)\)}{]($1)}g;
        # Anything else naming a bare file in the old directory has to climb
        # out. The archive-prefix test is what keeps the line above from being
        # undone: those targets are siblings now and must stay bare.
        s{\]\((?![0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-)([^)/]+\.md)\)}{](../$1)}g;
    ' "$1"
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

    # What travels is the new BASENAME, not a path: each citing file keeps
    # whatever prefix it used to reach the worklog and only the tail moves into
    # `archives/`, so `worklog/x.md`, `../x.md` and a bare `x.md` all stay
    # correct relative to where they are written.
    rewrite_citations "$root" "$slug" "$old_rel" "$(archive_name "$slug" "$stamp")" "$apply"
    info "$CITATION_COUNT file(s) cite this entry"

    if [[ "$apply" != "yes" ]]; then
        info "would set status to '$status' and move the file"
        return 0
    fi

    set_status "$old_abs" "$status"
    set_next_action "$old_abs" "${next_action:-none — closed ${stamp%-*}}"
    mkdir -p "$root/docs/worklog/archives"
    git -C "$root" mv "$old_rel" "$new_rel"
    relocate_own_links "$root/$new_rel"
    # `git mv` renames the INDEX ENTRY, carrying the blob as it was at HEAD — it
    # does not re-stage the working tree. Without this, the status stamp, the
    # Next-action clear, and relocate_own_links above all stay unstaged, and the
    # entry commits with its pre-close header and its own links unmoved. That
    # failure is invisible locally, because check-worklog.sh reads the working
    # tree and passes; CI reads the commit and does not. Must come AFTER
    # relocate_own_links, which edits the moved file.
    git -C "$root" add -- "$new_rel"
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
