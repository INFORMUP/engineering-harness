#!/usr/bin/env bash
#
# Provision node_modules for a git worktree so the pre-commit hook's whole-repo
# gates can run (adapted from the TaskFlow pilot).
#
# The pre-commit hook checks MULTIPLE package contexts (root formatter,
# per-package typecheck), so a worktree needs node_modules in each — fresh
# worktrees start with none. Each is symlinked from the primary checkout,
# falling back to an install when the primary lacks that package's
# node_modules. Symlinking also carries generated artifacts (e.g. an ORM
# client), sidestepping the fresh-worktree regenerate gotcha.
#
# Borrowing is only safe while the two checkouts agree on what belongs in
# node_modules, and the primary is parked on its own branch — so each package
# is compared against the primary first and installed in place when anything
# that shapes node_modules differs. See drift_sources() for what "anything"
# means and why a schema file is part of it.
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

# Files whose content determines what belongs in a package's node_modules. The
# manifests are the obvious half. A code-generating schema is the half that
# bites: node_modules also holds the *generated* client, whose source is the
# schema, not the lockfile — so a branch that changes the schema and no
# dependency drifts with a byte-identical lockfile, and the manifest comparison
# says borrowing is safe when it isn't.
#
# The symptom doesn't look like its cause: a missing model property surfaces as
# a type error in a file the commit never touched, often on a docs-only commit,
# reading as "main is broken" rather than "my client is stale".
#
# EDIT PER REPO: add any other codegen input (GraphQL schema, protobuf, OpenAPI
# spec) whose output lands in node_modules. Naming a file the repo doesn't have
# costs nothing — a path missing on either side is skipped.
drift_sources() {
  local rel="$1"
  echo package.json
  echo package-lock.json
  if [[ "$rel" == "backend" ]]; then
    echo prisma/schema.prisma
  fi
}

# True when this package would get a node_modules built from a different branch
# than the one the worktree is on.
drifts_from_primary() {
  local rel="$1" f
  while IFS= read -r f; do
    local mine="$HERE${rel:+/$rel}/$f" theirs="$PRIMARY${rel:+/$rel}/$f"
    [[ -e "$mine" && -e "$theirs" ]] || continue
    cmp -s "$mine" "$theirs" || return 0
  done < <(drift_sources "$rel")
  return 1
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
  # Borrow the primary's copy when we're a linked worktree, it has one, and the
  # two checkouts agree on what should be in it.
  if [[ "$PRIMARY" != "$HERE" && -d "$src" ]]; then
    if ! drifts_from_primary "$rel"; then
      ln -sfn "$src" "$dest"
      echo "  OK $label: symlinked node_modules <- primary checkout"
      return
    fi
    echo "==> $label: primary checkout is on a different branch's deps/schema — installing here instead of borrowing..."
  else
    echo "==> $label: no primary node_modules to borrow — installing..."
  fi
  # Installing through an inherited symlink would write into the PRIMARY's
  # node_modules — drop the link first so npm lands in this worktree.
  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi
  install_pkg "$HERE${rel:+/$rel}" "$label"
}

echo "Provisioning worktree node_modules (primary: $PRIMARY)"
for pkg in "${PACKAGES[@]}"; do
  provision "$pkg"
done

# EDIT PER REPO: regenerate per-package build artifacts a fresh install lacks,
# e.g. an ORM client (a symlink to the primary inherits it). Generating here can
# write THROUGH a symlink into the primary's node_modules — safe only because
# the symlink is now taken exclusively when the two schemas match, so the client
# generated is the one the primary would have generated for itself. Do not
# loosen the drift check without revisiting this.
# if [[ ! -d "$HERE/backend/node_modules/.prisma/client" ]]; then
#   (cd "$HERE/backend" && npx prisma generate >/dev/null)
# fi

echo "OK worktree ready"
