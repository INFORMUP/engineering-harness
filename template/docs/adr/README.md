# docs/adr/

One Architecture Decision Record per decision that is **settled, binding on future
work, and non-obvious from the code**. Start from `0000-template.md`.

The format is covered by the template and by the taxonomy row in
[../README.md](../README.md). This file covers the part neither of those answers:
**when an ADR is worth writing at all.**

## Why the judgment matters more than the format

An ADR directory fails in two directions, and the second is the common one.

Too few, and a deliberate design decision survives only in whoever made it — so
the next contributor (or the next agent) reads a constraint as an accident and
removes it.

Too many, and the directory stops being read. An ADR per dependency bump buries
the four that actually matter, and a record nobody opens is worse than no record,
because it *looks* like the decision was captured.

So the bar is deliberately high. Most decisions do not need one.

## The test

Write an ADR when any of the following holds. The categories in the taxonomy — new
dependency, schema change, cross-module design, auth/permission change — are where
these usually land, but they are the *typical locations*, not the test itself.

### 1. A deliberate constraint is indistinguishable from a bug

**Weight this highest.** A fail-closed default that throws where a permissive one
would return data; a gate deliberately narrower than it looks; a check that appears
redundant and isn't; a duplicated code path kept separate on purpose.

Code shows *what* it does. It cannot show which alternative was rejected, or that
the "simplification" sitting right there was considered and is wrong. Without the
record, the eventual outcome is not confusion — it is someone confidently deleting
a safety property and the tests staying green, because the property was about the
case the tests don't cover.

Every other trigger below costs rediscovery. This one causes damage, and it is the
one agents trip most, because an agent reading the file has none of the history a
long-tenured human still carries.

### 2. The rejected alternative is the obvious move, and it is actively harmful

Some decisions are cheap to state and expensive to re-derive because the *naive*
fix makes things worse rather than merely different — a retry that amplifies the
outage it was added for, a cache invalidation that opens the race it was meant to
close, a crawler block that strands already-indexed pages by preventing the fetch
that would reveal the `noindex`.

Here the decision is one line and the *rejection* is the whole record. If you find
yourself writing "and don't do X, because…" in a code comment that keeps growing,
that is an ADR asking to be written.

### 3. The decision spans modules or repos

Anything true of the system rather than of one file has no natural home in the
code — how services authenticate to each other, which of two stores owns a kind of
secret, what the merge/branching contract is, which layer is allowed to talk to
which. It ends up pasted into whichever module the author happened to be in, and
then diverges.

### 4. You are re-deriving an answer you have reached before

Re-litigation is the cheapest signal available. The second time a question is
argued from scratch, the reasoning demonstrably did not get written down anywhere
findable — write it down now, while it is reconstructed and fresh.

## When *not* to write one

- **Reversible decisions.** If it can be changed later at roughly the cost of
  making it now, it does not need a durable record. The cost of reversal is the
  real measure, not how much was discussed.
- **Decisions the code makes obvious.** If reading the module answers "why is it
  like this?", an ADR just adds a second copy that will go stale.
- **Decisions nobody will revisit.** Not everything considered is contested.
- **Routine applications of an existing decision.** Adding the fourth service that
  follows an established pattern is not a new decision — it is the old one working.
  If the pattern itself was never recorded, record *that*, once.

## Relationship to the worklog, this repo's CLAUDE.md, and the issue tracker

Four places hold reasoning; the boundary is what state the item is in.

| | Holds | State | Closed by |
|---|---|---|---|
| `docs/worklog/` | An issue found in passing, or an open question — with evidence and rejected approaches | **Open** | Humans only |
| `docs/adr/` | A decision that has been made, with the options that lost | **Settled** | Immutable; superseded, never edited |
| `/CLAUDE.md` | A settled constraint whose reasoning fits in a bullet | Settled, short | Living — edited freely |
| Issue tracker | Work someone outside the session must act on | Scheduled | Task workflow |

Two rules follow:

**Reach for an ADR when the *why* outgrows a CLAUDE.md bullet but still has to be
found at the moment someone is about to violate it.** Short constraints belong in
`CLAUDE.md`, and that is not a consolation prize — it is the strictly better
channel, because agents read that file every session and read `docs/adr/` only when
something sends them there. The reason to move a decision out is that its rationale
has grown long enough to dilute a file whose value depends on staying skimmable.
When you do move it, leave a one-line pointer behind in `CLAUDE.md`. An ADR nothing
links to is an ADR nobody opens.

**Promote a resolved worklog entry by link, not by copy.** When an entry's
resolution establishes a lasting constraint, write the ADR for the constraint and
the rejected option; the archived entry keeps the evidence and the dead ends, and
the two cite each other. Copy the reasoning into both and the current version lives
in whichever was edited last — the same failure the worklog↔tracker rule exists to
prevent.

Most worklog entries never become ADRs. Resolving as "looked at this, it's fine" is
a complete outcome.

## Lifecycle

- **Numbering** is sequential and permanent: `NNNN-short-title.md`, starting at
  `0001`. Numbers are never reused, including for abandoned ADRs.
- **Status** is `Proposed` while the PR is open, `Accepted` on merge.
- **Superseding**: a change of course is a *new* ADR. The PR that accepts it also
  flips the old file's Status line to `Superseded-by-NNNN` — that flip is the only
  edit an accepted ADR ever receives. Do not delete the old file; the point of the
  record is that the earlier reasoning stays readable.
- **Approval** is a senior/CODEOWNERS decision. Agents draft ADRs; they do not
  decide that a decision is settled.
