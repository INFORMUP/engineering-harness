#!/usr/bin/env bash
# Copy an opt-in module into a target repo (working tree). Same never-overwrite
# contract as install.sh: conflicts are reported for manual merge.
#
# Modules are the parts of the harness that only make sense for some repos —
# a specific tracker, a specific stack. Keeping them out of template/ is what
# lets install.sh stay honest about being universal.
#
# Usage:  scripts/install-module.sh <module> /path/to/target-repo
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULES="$DIR/modules"

MODULE="${1:-}"
TARGET="${2:-}"

if [[ -z "$MODULE" || -z "$TARGET" ]]; then
  echo "usage: install-module.sh <module> /path/to/target-repo"
  echo
  echo "available modules:"
  for m in "$MODULES"/*/; do
    [[ -d "$m" ]] && echo "  $(basename "$m")"
  done
  exit 1
fi

SRC="$MODULES/$MODULE"
[[ -d "$SRC" ]] || { echo "ERROR: no module '$MODULE' under modules/"; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "ERROR: $TARGET is not a git repo"; exit 1; }

copied=0; skipped=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  # The module's own README documents the module; it isn't part of the payload.
  [[ "$rel" == "README.md" ]] && continue
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

chmod +x "$TARGET/.github/scripts/"*.sh 2>/dev/null || true

echo
echo "Copied $copied file(s), skipped $skipped existing."
echo
echo "Manual follow-ups: see modules/$MODULE/README.md § Install"
