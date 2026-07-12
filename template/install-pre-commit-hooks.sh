#!/usr/bin/env bash
#
# Activate this repo's git hooks (.githooks/) for the current clone.
#
# Run once at the start of a working session (idempotent — safe to re-run).
# core.hooksPath is set at the repo level, so a single run covers this checkout
# and every worktree created from it. Without this, the pre-commit hook never
# fires and commits skip the gates that CI then enforces — a red build you
# could have caught locally. Reference it from CLAUDE.md's session-setup note
# so agents run it before their first commit.
#
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
git -C "$ROOT" config core.hooksPath .githooks

echo "✓ git hooks activated (core.hooksPath = .githooks)"
