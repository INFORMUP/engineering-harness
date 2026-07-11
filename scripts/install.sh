#!/usr/bin/env bash
# Copy the harness template into a target repo (working tree). Never
# overwrites existing files — conflicts are reported for manual merge.
#
# Usage:  scripts/install.sh /path/to/target-repo
set -euo pipefail

TARGET="${1:?usage: install.sh /path/to/target-repo}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/template"

[[ -d "$TARGET/.git" ]] || { echo "ERROR: $TARGET is not a git repo"; exit 1; }

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
 1. .github/CODEOWNERS.example → rename to CODEOWNERS, fill ≥2 owners per path.
 2. Splice template CLAUDE-sections.md into the repo's root CLAUDE.md,
    then DELETE CLAUDE-sections.md from the target.
 3. Wire your test workflow: run tests with a json-summary coverage reporter,
    then call .github/scripts/coverage-ratchet.sh <package-key> from each
    package dir. Keys must match .github/coverage-baseline.json (floors ship
    null — pin them from your first CI run's reported numbers).
 4. Edit .githooks/pre-commit for your stack; activate hooks with:
       git config core.hooksPath .githooks
 5. pr-gates.yml: adjust EXCLUDE_GLOBS (generated paths) and, for non-JS
    stacks, extend SUPPRESS_RE (noqa, type: ignore, pragma: no cover...).
 6. Reuse surface: set SURFACE_DIRS in scripts/generate-inventory.mjs and the
    matching REUSE_PATHS in pr-gates.yml (lockstep!), then seed the index:
       node scripts/generate-inventory.mjs
 7. TS stacks: add the lint-level suppression rules (see README §Suppressions).
 8. Create the 'size-override' and 'coverage-override' labels:
       gh label create size-override; gh label create coverage-override
 9. Make it all binding:
       scripts/install-ruleset.sh ORG/REPO <your-check-names>
EOF
