#!/usr/bin/env bash
# Apply the TWO-ruleset review gate to a repo. Requires: gh (authed with repo
# admin), jq. GitHub Team/Pro plan required for private repos.
#
# Usage:
#   scripts/install-ruleset.sh ORG/REPO check1,check2,...
#
# Example (checks = CI job names your workflows expose on PRs):
#   scripts/install-ruleset.sh INFORMUP/my-repo backend,frontend,gates,lint-pr-title,format
#
# WHY TWO RULESETS (learned on the TaskFlow pilot — do not recombine):
#   main-integrity  — required checks, linear history, no force-push/deletion.
#                     NO bypass actors: nobody, admins included, can merge red
#                     CI or push directly to main.
#   main-review     — squash-only, review-thread resolution, stale-approval
#                     dismissal, and ONE approving CODEOWNER review. Repo
#                     admins may bypass THIS ruleset only, and only through a
#                     PR (`gh pr merge --admin --squash`).
# The split is what makes an admin override safe: `--admin` waives the review
# rule and nothing else. A single combined ruleset with an admin bypass lets
# admins merge failing builds and push straight to main.
#
# CODEOWNERS PHILOSOPHY (see CODEOWNERS.example): exactly ONE senior owner per
# path. GitHub forbids self-approval, so the senior's own PRs read
# BLOCKED/REVIEW_REQUIRED forever — that is expected; their merge path is
# `--admin` after green checks. Do NOT add a second owner to "fix" this: if the
# second owner is a junior, every junior's PR can then be approved by them.
set -euo pipefail

REPO="${1:?usage: install-ruleset.sh ORG/REPO check1,check2,...}"
CHECKS="${2:?comma-separated required check names (CI job names) required}"

DIR="$(cd "$(dirname "$0")/.." && pwd)"

apply_ruleset() {
  local name="$1" payload="$2"
  local existing
  existing=$(gh api "repos/$REPO/rulesets" --jq "[.[] | select(.name==\"$name\")][0].id // empty")
  if [[ -n "$existing" ]]; then
    echo "Updating existing ruleset '$name' ($existing) on $REPO..."
    echo "$payload" | gh api -X PUT "repos/$REPO/rulesets/$existing" --input - --jq '{id, name, enforcement}'
  else
    echo "Creating ruleset '$name' on $REPO..."
    echo "$payload" | gh api -X POST "repos/$REPO/rulesets" --input - --jq '{id, name, enforcement}'
  fi
}

INTEGRITY=$(jq --arg checks "$CHECKS" '
  (.rules[] | select(.type=="required_status_checks").parameters.required_status_checks) |=
    ($checks | split(",") | map({context: .}))
  ' "$DIR/rulesets/main-integrity.template.json")

REVIEW=$(cat "$DIR/rulesets/main-review.template.json")

apply_ruleset "main-integrity" "$INTEGRITY"
apply_ruleset "main-review" "$REVIEW"

# Migration from the harness's original single-ruleset design.
LEGACY=$(gh api "repos/$REPO/rulesets" --jq '[.[] | select(.name=="main-protection")][0].id // empty')
if [[ -n "$LEGACY" ]]; then
  echo "WARNING: legacy 'main-protection' ruleset ($LEGACY) still exists — it grants"
  echo "an always-on admin bypass the split exists to remove. Delete it with:"
  echo "  gh api -X DELETE repos/$REPO/rulesets/$LEGACY"
fi

echo "Setting squash-only merges (PR title/body become the squash commit)..."
gh api -X PATCH "repos/$REPO" \
  -f allow_squash_merge=true -f allow_merge_commit=false -f allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  --jq '{squash: .allow_squash_merge, merge_commit: .allow_merge_commit, rebase: .allow_rebase_merge}'

echo "Verifying effective rules on the default branch..."
DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
gh api "repos/$REPO/rules/branches/$DEFAULT" --jq '[.[].type] | sort | unique'

echo "Done. $REPO is gated: checks unbypassable (main-integrity), review by CODEOWNER"
echo "with a PR-only admin waiver for the senior's own PRs (main-review)."
