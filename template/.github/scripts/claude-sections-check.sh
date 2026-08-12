#!/usr/bin/env bash
# Assert this repo's root CLAUDE.md carries the shared harness sections.
#
# WHY THIS EXISTS
#
# The harness ships its agent-facing guidance as template/CLAUDE-sections.md,
# a file the installer copies in and then asks a human to splice into the
# repo's own CLAUDE.md by hand (install.sh follow-up #2). Nothing verified the
# splice, and across the first six INFORMUP consumers it never happened once:
# every repo deleted the copied file without merging its contents, so sections
# the harness considered shipped — Worklog, Tenant scoping — reached no repo at
# all. Agents read CLAUDE.md every session, so guidance that never lands there
# is guidance that does not exist, and the failure is silent in both
# directions: the harness looks like it shipped, and the repo looks compliant.
#
# So the gate checks the DESTINATION, not the delivery. Asserting the copied
# file is gone would have passed in all six repos — the file was gone; the
# content had simply never been merged. What must be true is that the sections
# are IN CLAUDE.md, and that is what this asserts.
#
# WHAT IT CANNOT SEE
#
# Headings, not prose. A section spliced in as a heading with nothing under it
# passes, as does one whose body has drifted from the harness's wording. That
# is deliberate: the body is meant to be adapted per repo (stack-specific
# commands, repo-specific examples), so diffing it against the template would
# fail every honest customization and train people to bypass the gate. The
# heading is the contract; the prose beneath it belongs to the repo.
#
# Usage:  bash .github/scripts/claude-sections-check.sh [repo-root]
set -uo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MANIFEST="$ROOT/.github/claude-sections.manifest"
CLAUDE_MD="$ROOT/CLAUDE.md"
HARNESS_SOURCE="engineering-harness template/CLAUDE-sections.md"

fail() { echo "::error::$*"; }

if [[ ! -f "$MANIFEST" ]]; then
  fail "no manifest at .github/claude-sections.manifest — re-run the harness installer"
  exit 1
fi

if [[ ! -f "$CLAUDE_MD" ]]; then
  fail "no CLAUDE.md at the repo root. The harness sections live there because that is the file agents read every session; a repo with the gates but no CLAUDE.md gets the enforcement without the guidance."
  exit 1
fi

# A manifest line is a required heading when it starts with '## ', and a
# comment when it starts with '#' and does not. The two overlap by one
# character, so order matters here: test for the heading form FIRST. Stripping
# '#'-comments before extracting headings would consume the entire manifest.
required=()
while IFS= read -r line; do
  line="${line%"${line##*[![:space:]]}"}" # strip trailing whitespace
  if [[ "$line" == '## '* ]]; then
    required+=("$line")
  fi
done <"$MANIFEST"

if [[ ${#required[@]} -eq 0 ]]; then
  fail "manifest lists no '## ' headings — it is empty or malformed, so this gate would pass vacuously"
  exit 1
fi

missing=()
for heading in "${required[@]}"; do
  # -F -x: whole-line literal match, so '## Code Style' does not satisfy
  # '## Code Style Guide' and a heading mentioned mid-prose does not count.
  if ! grep -Fxq "$heading" "$CLAUDE_MD"; then
    missing+=("$heading")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  for heading in "${missing[@]}"; do
    fail "CLAUDE.md is missing the harness section: $heading"
  done
  cat >&2 <<EOF

== HARNESS SECTIONS NOT SPLICED ==
${#missing[@]} of ${#required[@]} shared sections are absent from CLAUDE.md.

These are the agent-facing half of the harness: CI enforces the mechanical
rules, and these sections are what make agents generate conforming work in the
first place rather than having it bounced. A missing section is guidance no
agent working in this repo will ever read.

To fix: copy each missing section from $HARNESS_SOURCE into this repo's root
CLAUDE.md, keeping the heading text exactly as listed in
.github/claude-sections.manifest. Adapt the prose underneath to this repo --
stack-specific commands and examples are expected to differ. If a section
genuinely does not apply here, drop its line from the manifest in the same PR
and say why in the PR body, so the exemption is reviewed rather than assumed.
EOF
  exit 1
fi

# An un-spliced leftover is a weaker signal than the check above (it was absent
# in every repo that had skipped the splice), but if the file IS still sitting
# here after a passing splice, it is a stale copy that will drift from the
# harness and mislead the next reader.
leftovers="$(git -C "$ROOT" ls-files '*CLAUDE-sections.md' 2>/dev/null || true)"
if [[ -n "$leftovers" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && fail "delete the installer's copy once spliced, it goes stale: $f"
  done <<<"$leftovers"
  exit 1
fi

echo "claude sections: OK — all ${#required[@]} harness section(s) present in CLAUDE.md"
exit 0
