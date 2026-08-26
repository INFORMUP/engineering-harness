#!/usr/bin/env bash
# Copy the harness template into a target repo (working tree). Never
# overwrites existing files — conflicts are reported for manual merge.
#
# Usage:  scripts/install.sh /path/to/target-repo
set -euo pipefail

TARGET="${1:?usage: install.sh /path/to/target-repo}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/template"

# -e, not -d: in a linked worktree (and in a submodule) `.git` is a FILE holding
# a `gitdir:` pointer. Every INFORMUP repo is worked in worktrees by convention,
# so a directory-only test refuses the normal case.
[[ -e "$TARGET/.git" ]] || { echo "ERROR: $TARGET is not a git repo"; exit 1; }

copied=0; skipped=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  dest="$TARGET/$rel"
  if [[ -e "$dest" ]]; then
    echo "SKIP (exists, merge manually): $rel"
    skipped=$((skipped+1))
  else
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest"
    copied=$((copied+1))
  fi
done < <(find "$SRC" -type f -print0)

chmod +x "$TARGET/.githooks/"* "$TARGET/.github/scripts/"*.sh 2>/dev/null || true

cat <<EOF

Copied $copied file(s), skipped $skipped existing.

Manual follow-ups (the parts that are per-stack by design):
 1. .github/CODEOWNERS.example → rename to CODEOWNERS; list exactly the
    senior engineer(s) — usually ONE. See the file header for why a second
    non-senior owner dissolves the review gate.
 2. Splice template CLAUDE-sections.md into the repo's root CLAUDE.md,
    then DELETE CLAUDE-sections.md from the target. Keep each '## ' heading
    verbatim; adapt the prose under it to this stack.
    This one is VERIFIED, not trusted: the pr-gates 'CLAUDE.md harness
    sections' step fails while any heading in
    .github/claude-sections.manifest is absent from CLAUDE.md. Skipping the
    splice was the default outcome before that gate existed — it happened in
    every one of the first six consumer repos — so expect red CI until it is
    done. If a section truly doesn't apply here, drop its manifest line in the
    same PR rather than leaving the gate red.
 3. Wire your test workflow: run tests with a json-summary coverage reporter,
    then call .github/scripts/coverage-ratchet.sh <package-key> from each
    package dir. Keys must match .github/coverage-baseline.json (floors ship
    null — pin them from your first CI run's reported numbers).
 4. Configure .githooks/pre-commit for your stack. It ships with
    TYPECHECK=unconfigured and REFUSES every commit until you set it to
    `configured` (and fill in the commands below it) or to `none` (this repo
    has no typecheck). It fails closed on purpose: the block used to ship
    commented out, four repos never adapted it, and their hooks announced
    "checks passed" having verified nothing. Commit the change — the decision
    belongs in version control so every clone inherits it. Then activate hooks:
       ./install-pre-commit-hooks.sh
    Add the session-setup note to CLAUDE.md so agents run it too (see
    CLAUDE-sections.md's Commit Workflow). Agents working in git worktrees
    should also run ./setup-worktree.sh (edit its PACKAGES list, and its
    drift_sources() if a codegen schema feeds node_modules) so the
    hook's whole-repo gates have node_modules to run against.
 5. pr-gates.yml: adjust EXCLUDE_GLOBS (generated paths) and, for non-JS
    stacks, extend SUPPRESS_RE (noqa, type: ignore, pragma: no cover...).
 6. Reuse surface: set SURFACE_DIRS in scripts/generate-inventory.mjs and the
    matching REUSE_PATHS in pr-gates.yml (lockstep!), then seed the index:
       node scripts/generate-inventory.mjs
 7. TS stacks: add the lint-level suppression rules (see README §Suppressions).
 8. Worklog: docs/worklog/ ships a template, a CLAUDE.md of conventions, and
    two scripts (.github/scripts/check-worklog.sh, archive-worklog.sh). The
    checker is a pr-gates step and is NOT diff-scoped — it asserts a property
    of the whole directory — so a repo with existing entries goes red until
    they conform. Size the work first:
       bash .github/scripts/check-worklog.sh
    Close entries with archive-worklog.sh, never a hand `git mv`: it repoints
    every citation of the entry, and a missed one fails the next PR, not yours.
 9. Create the 'size-override' and 'coverage-override' labels:
       gh label create size-override; gh label create coverage-override
 10. Make it all binding:
       scripts/install-ruleset.sh ORG/REPO <your-check-names>
EOF
