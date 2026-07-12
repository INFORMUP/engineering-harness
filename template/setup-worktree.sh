#!/usr/bin/env bash
#
# Provision node_modules for a git worktree so the pre-commit hook's whole-repo
# gates can run (adapted from the TaskFlow pilot).
#
# The pre-commit hook checks MULTIPLE package contexts (root formatter,
# per-package typecheck), so a worktree needs node_modules in each — fresh
# worktrees start with none. Each is symlinked from the primary checkout,
# falling back to an install when the primary lacks that package's
# node_modules. Symlinking also carries generated artifacts (e.g. a Prisma
# client), sidestepping the fresh-worktree regenerate gotcha.
#
# Idempotent; run once from inside a freshly-created worktree:
#   ./setup-worktree.sh
#
set -euo pipefail

# EDIT PER REPO: package dirs relative to the repo root ("" = root).
PACKAGES=("" "backend" "frontend")

HERE="$(git rev-parse --show-toplevel)"

# Resolve the primary checkout. --git-common-dir points at the shared git dir
# (for a submodule that is .git/modules/<path>, NOT the checkout), so derive
# the working tree from its core.worktree; a plain clone leaves that unset,
# where the checkout is simply the parent of the git dir.
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
WT="$(git config --file "$COMMON_DIR/config" core.worktree 2>/dev/null || true)"
if [[ -n "$WT" ]]; then
  PRIMARY="$(cd "$COMMON_DIR" && realpath "$WT")"
else
  PRIMARY="$(dirname "$COMMON_DIR")"
fi

install_pkg() {
  local dir="$1" label="$2"
  if [[ -f "$dir/package-lock.json" ]]; then
    (cd "$dir" && npm ci)
  else
    (cd "$dir" && npm install)
  fi
  echo "  OK $label: installed in place"
}

provision() {
  local rel="$1"
  local label="${rel:-root}"
  local dest="$HERE${rel:+/$rel}/node_modules"
  local src="$PRIMARY${rel:+/$rel}/node_modules"

  # A real (non-symlink) node_modules is a deliberate in-place install — leave it.
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    echo "  OK $label: node_modules already present — leaving as-is"
    return
  fi
  # Borrow the primary's copy when we're a linked worktree and it has one.
  if [[ "$PRIMARY" != "$HERE" && -d "$src" ]]; then
    ln -sfn "$src" "$dest"
    echo "  OK $label: symlinked node_modules <- primary checkout"
    return
  fi
  echo "==> $label: no primary node_modules to borrow — installing..."
  install_pkg "$HERE${rel:+/$rel}" "$label"
}

echo "Provisioning worktree node_modules (primary: $PRIMARY)"
for pkg in "${PACKAGES[@]}"; do
  provision "$pkg"
done

# EDIT PER REPO: regenerate per-package build artifacts a fresh install lacks,
# e.g. an ORM client (a symlink to the primary inherits it):
# if [[ ! -d "$HERE/backend/node_modules/.prisma/client" ]]; then
#   (cd "$HERE/backend" && npx prisma generate >/dev/null)
# fi

echo "OK worktree ready"
