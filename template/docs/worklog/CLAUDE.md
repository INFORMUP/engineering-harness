# docs/worklog/

Issues found in passing, and the reasoning behind them. One file per item.

**Write the entry when you find the item, not when you start working on it.** That
is the whole discipline. At discovery you have just run the command and read the
file, so the evidence is free; an hour or a compaction later the same entry costs a
re-investigation, and the reconstructed version is worse than the recorded one.

Start from `0000-template.md`. Name the file for the issue, not the date
(`social-post-media-broken-in-prod.md`, not `2026-08-02-bug.md`) — the discovery
date lives in the entry, and the resolution date arrives with the archive prefix.

`.github/scripts/check-worklog.sh` enforces the mechanical half of what follows (header
shape, status vocabulary, archive placement, filename/title agreement) and runs in
CI. Run it locally before committing an entry; it exits non-zero on a violation and
`--list` prints every entry's state as a table.

## Correct above the rule; append below it

Every entry has two halves, split by a `---` rule.

- **Above the rule is the head** — title, status block, Observation, Evidence, Why
  it matters, Approaches considered. It is **present tense, and rewritten in place
  on every update.** A reader who stops at the end of the head must not be
  misinformed.
- **Below the rule is the log** — dated `### YYYY-MM-DD — …` sections, append-only,
  plus the Resolution. Nothing there is guaranteed current.

**This exists because appending is the natural motion and it silently rots the top
of the file.** An update arrives as "here is what happened on the 12th", gets added
at the bottom, and the paragraph three screens up goes on asserting the opposite in
the present tense with nothing marking it stale. Two real examples, from the
worklog this convention was extracted from: an entry whose head said an environment
"is parked, so this must not be flipped" while its own log, forty lines down,
recorded that the environment had been terminated; another whose bolded "still open,
and here is why" sat above the section recording the work as done.

So when a log entry contradicts the head, **the head is what's wrong.** Go up and
fix the sentence. Do not add a third paragraph reconciling the first two.

**Record the shape of a correction, not just the corrected fact.** The most useful
thing in this directory is a line naming *how* the mistake was possible — "the root
of both errors was reading a code default as though it were the deployed value" —
because that generalizes and the fact doesn't. Put the correction's substance in the
log and the corrected claim in the head.

## Keep entries small enough to stay true

An entry is one item. When it stops being one, split it rather than growing it:

- **The subject changed.** Investigation moves; the file name doesn't follow on its
  own. When the title no longer describes what the entry is about, `git mv` the file
  to a slug that matches and fix the inbound links (`grep -rl '<old-name>' --include='*.md' --include='*.sh' .`).
  The checker flags a filename whose slug shares no word with its title.
- **It grew past roughly 1,500 words.** That is not a hard cap — a genuinely large
  single item can earn it — but it is the point to ask whether two or three items
  are sharing a file because they share a *resource*. When part of it has resolved,
  cut that part to `archives/` as its own entry and leave a one-line link.

Prose is what accumulates, not evidence. Command output runs 6–18% of a typical
entry here and is the half worth keeping; a "Why it matters" that restates the
Observation in different words is the half to cut.

## Resolving and archiving

When an entry is resolved, move it to `docs/worklog/archives/` and prepend a
completion timestamp in `YYYY-MM-DD-HHMM-` format (UTC), the same convention
`docs/plans/` uses:

```
docs/worklog/social-post-media-broken-in-prod.md
  →  docs/worklog/archives/2026-08-02-1130-social-post-media-broken-in-prod.md
```

Set `Status:` in the same commit — a file under `archives/` still reading `open` is
the most common bookkeeping error, because the status line is furthest from wherever
the resolution was typed. Use `superseded` when the entry was overtaken rather than
fixed (the resource went away, another entry absorbed it).

### The four rungs

The slot holds **one bare word**. Anything else — a date, a clause, a "see below" —
goes on the `Next action:` line, where it can be prose without making the status
column uncountable.

| status | means | lives in |
|---|---|---|
| `open` | someone still owes this something | `docs/worklog/` |
| `fixed` | the work landed; only a human close remains | `docs/worklog/` |
| `resolved` | closed | `archives/` |
| `superseded` | overtaken rather than fixed — the resource went away, another entry absorbed it | `archives/` |

**`fixed` is the rung that keeps `open` honest.** Without it, an entry whose fix
shipped sits at `open` indistinguishably from one nobody has touched, and the
directory stops being able to answer the only question it exists to answer. Set it
the moment the change lands; **only a human moves an entry off it**, which is the
same rule as before — an agent may fix and may write the Resolution, but does not decide
an item is closed.

The word replaces the qualifier, it does not accompany it: write `fixed`, not
`fixed, awaiting close`. The checker rejects the second.

**Do not do this by hand — run the script:**

```
.github/scripts/archive-worklog.sh <slug>            # dry run: shows what would move and what cites it
.github/scripts/archive-worklog.sh <slug> --apply
```

It stamps the status, clears any stale `Next action:`, `git mv`s the file under
the timestamped name, and **repoints every citation of the entry in the repo** —
then runs the checker. That last part is why it exists: entries are cited by
path from the code they describe, and the ones worth archiving are the
heavily-cited ones (in the originating repo, one entry was named in ten files,
including a CI workflow). A hand-move leaves those dangling, and `check-worklog.sh` rejects a
dangling reference wherever it finds one — so the breakage lands on whoever
opens the next PR, not on you.

Its one blind spot is a citation in **another repository**. A repo that vendors
others as submodules names entries in their `docs/worklog/`, and they name
entries back. Nothing rewrites those and no checker sees them, so grep the other
repo by hand when closing an entry you know it references.

Do not delete resolved entries. The archive is where trends across many entries
become visible, which is half the reason the log exists.

## What belongs here vs. in TaskFlow

The test is **not** size or effort — it's whether someone outside the session needs
to act on the item.

- **TaskFlow** — needs scheduling, a review gate, acceptance criteria, or is
  tracked as a deliverable. Work someone could be assigned.
- **Worklog** — everything else, *including things that will never be done*.
  "I looked at this, here's why it's fine" is a legitimate entry, and TaskFlow
  has no resting place for it.

**Promote by link, not by copy.** When an entry graduates, the TaskFlow task body
cites the worklog path and the entry records the task id. TaskFlow owns status and
scheduling; this directory owns evidence and reasoning. Copy the reasoning into
both and the current version ends up in whichever was written last.

**The same rule governs `CLAUDE.md`, and it is easier to break there.** A finding
worth remembering is tempting to restate in the context file every session loads —
and then there are two copies of the evidence, drifting. What belongs in a
`CLAUDE.md` is the *standing constraint* an agent must not violate, in a sentence or
two, plus the path to the entry: "re-enabling this distribution re-opens
unauthenticated read of the whole bucket — see `docs/worklog/<entry>.md`". The
history, the probe output, and the reasoning stay here.

## Rules

- **An entry belongs to the repo whose code it describes.** An issue in a vendored
  or sibling repo gets its entry in *that* repo's `docs/worklog/`, so it travels
  with the code and an agent working there finds it. What lands here is this
  repo's own business.
- **Read the existing entries before filing** — both to avoid a third copy of the
  same observation and to find the entry that already explains it.
- **Filing is not permission to act.** An entry is parked, not started; writing one
  doesn't license a detour from the task actually requested.
- **Only humans resolve entries.** Agents file them, add evidence to them, and
  append resolutions once the work lands — they don't decide an item is closed.
- **Mutable state is a lead, not a fact.** Date any claim about live
  infrastructure config, deploy status, or DB contents, and record the command
  that re-checks it rather than the verdict alone. A claim that can become false
  without a commit has no moment at which anyone would notice it drift.
