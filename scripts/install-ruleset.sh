#!/usr/bin/env bash
# Apply the main-protection ruleset to a repo. Requires: gh (authed with repo
# admin), jq. GitHub Team/Pro plan required for private repos.
#
# Usage:
#   scripts/install-ruleset.sh ORG/REPO check1,check2,...  [--no-codeowner-review]
#
# Example (checks = job names your CI exposes on PRs):
#   scripts/install-ruleset.sh INFORMUP/my-repo backend,frontend,gates,lint-pr-title
#
# DEADLOCK WARNING: require_code_owner_review is ON by default. GitHub does
# not count self-approval, so CODEOWNERS must list AT LEAST TWO people per
# path or the sole owner's PRs can never merge. Pass --no-codeowner-review to
# start relaxed, then re-run without the flag after CODEOWNERS is fixed
# (re-running updates the existing ruleset in place).
set -euo pipefail

REPO="${1:?usage: install-ruleset.sh ORG/REPO check1,check2,... [--no-codeowner-review]}"
CHECKS="${2:?comma-separated required check names (CI job names) required}"
CODEOWNER_REVIEW=true
[[ "${3:-}" == "--no-codeowner-review" ]] && CODEOWNER_REVIEW=false

DIR="$(cd "$(dirname "$0")/.." && pwd)"

PAYLOAD=$(jq \
  --argjson codeowner "$CODEOWNER_REVIEW" \
  --arg checks "$CHECKS" '
  (.rules[] | select(.type=="pull_request").parameters.require_code_owner_review) |= $codeowner |
  (.rules[] | select(.type=="required_status_checks").parameters.required_status_checks) |=
    ($checks | split(",") | map({context: .}))
  ' "$DIR/rulesets/main-protection.template.json")

EXISTING=$(gh api "repos/$REPO/rulesets" --jq '[.[] | select(.name=="main-protection")][0].id // empty')

if [[ -n "$EXISTING" ]]; then
  echo "Updating existing ruleset $EXISTING on $REPO..."
  echo "$PAYLOAD" | gh api -X PUT "repos/$REPO/rulesets/$EXISTING" --input - --jq '{id, name, enforcement}'
else
  echo "Creating ruleset on $REPO..."
  echo "$PAYLOAD" | gh api -X POST "repos/$REPO/rulesets" --input - --jq '{id, name, enforcement}'
fi

echo "Setting squash-only merges (PR title/body become the squash commit)..."
gh api -X PATCH "repos/$REPO" \
  -f allow_squash_merge=true -f allow_merge_commit=false -f allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  --jq '{squash: .allow_squash_merge, merge_commit: .allow_merge_commit, rebase: .allow_rebase_merge}'

echo "Verifying effective rules on the default branch..."
DEFAULT=$(gh api "repos/$REPO" --jq .default_branch)
gh api "repos/$REPO/rules/branches/$DEFAULT" --jq '[.[].type] | sort | unique'

echo "Done. Gates on $REPO are now binding (codeowner review: $CODEOWNER_REVIEW)."
