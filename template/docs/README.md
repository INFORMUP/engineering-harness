# Documentation taxonomy

Every doc in this repo has a type, an owner, and a lifecycle. This index answers
"where does this get written down, and who approves it?" for both humans and
agents. If you're adding documentation that doesn't fit a row below, propose a
new row in the same PR.

<!-- Template note: the rows below are the universal doc types the engineering
     harness assumes. Add rows for your repo's own docs (domain references,
     build plans, generated docs) — and mark generated docs "never hand-edit". -->

## The taxonomy

| Doc | Purpose | Drafted by | Approved by | Updated when | Lifecycle |
|---|---|---|---|---|---|
| `/CLAUDE.md` | Agent operating contract: conventions, Definition of Done, Mistakes log | Agents may propose | Senior review (CODEOWNERS) | A review finding recurs → codify it | Living |
| `/OVERVIEW.md` | Product + architecture orientation for humans and agents | Agent | Senior review | Architecture materially changes | Living |
| `docs/style.md` | House style guide (inherits a public parent guide); records deviations and judgment rules only | **Humans only** — agents never edit (see file header) | Senior review | Human-led decision, via `style-update`-labeled PR | Living |
| Domain reference docs | Current truth about one domain (schema, API, permissions, …) | Contributor's agent, **in the same PR as the code change** | PR review | The code they describe changes | Living |
| `docs/inventory.md` | **Generated** reuse-surface index (exported services/utils/composables + one-line summaries) — consult before writing any new helper | `scripts/generate-inventory.mjs` — **never hand-edit** | Drift-checked in CI | Reuse-surface exports change | Generated |
| `docs/adr/` | One Architecture Decision Record per major decision: context, options, rationale, consequences | Contributor's agent | Senior (CODEOWNERS) | New dependency, schema change, cross-module design, auth change | Immutable once accepted; superseded, never edited |
| `docs/plans/` | Pre-implementation contracts for plan-required work | Planning workflow | Senior (plan-PR merge = approval) | Plan-required paths touched | Draft → approved → implemented → `archive/` |
| `docs/audits/` | Dated codebase-audit reports | Audit agent | Senior triage | Scheduled cadence | Append-only |
| `docs/README.md` | This taxonomy | — | Senior | Taxonomy changes | Living |

## Cross-cutting rules

1. **Docs ride in the same PR as the code they describe.** A separate
   "docs catch-up PR" is the failure mode this taxonomy exists to prevent. The
   PR template's *Docs touched* section is where you attest to this.
2. **Generated docs are never hand-edited.** Regenerate them instead, and
   drift-check them in CI.
3. **Archive, don't delete.** Completed working docs move to their directory's
   `archive/`. History stays greppable.
4. **Immutable types get superseded, not edited.** Accepted ADRs and historical
   records are snapshots; a change of course is a *new* doc that marks the old
   one superseded.
5. **When code review finds a docs gap twice, promote the rule** — into
   `CLAUDE.md` (agent behavior), `docs/style.md` (style judgment, human-led), or
   a domain doc (system truth). That feedback loop is the point of the system.
