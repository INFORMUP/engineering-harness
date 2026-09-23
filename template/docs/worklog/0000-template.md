# <short title: what's wrong, in behavioral terms>

- **In one line:** <the observation, in one sentence>
- **Status:** open <!-- open | fixed | resolved | superseded — one bare word, nothing else -->
- **Next action:** <what has to happen next, and whose call it is — prose belongs here, not in the status slot>
- **Found:** <YYYY-MM-DD>, while <what you were actually doing when this surfaced>
- **Escalated:** no <!-- or: <tracker task id> — see "promote by link, not by copy" in CLAUDE.md -->

<!-- `In one line:` and `Next action:` are the lede, and they are not optional.

     They exist because an entry has two readers with opposite needs: someone
     deciding what to do next, who needs two lines, and someone reconstructing
     why a decision was made, who needs the whole thing. Without a lede both
     pay the longer price, and the cost of *finding* the right entry grows with
     the length of every other entry in the directory. With one, the body below
     may run as long as the item genuinely deserves. Keep `Next action:` to one
     sentence — "nothing yet" and "a human close" are fine answers.

     An item whose lede will not fit in two sentences is usually two items.

     If you found AND fixed this in the change you are writing right now, it is
     not an entry at all — put the reasoning in a comment at the line someone
     would next edit, and the evidence in the PR body. See the filing floor in
     CLAUDE.md.

     The sections below are this entry's MAXIMUM shape, not a checklist to
     fill in. A fifteen-line entry carrying an observation and the command that
     produced it is a complete entry. Write the sections the item actually has;
     a heading padded to look thorough costs every future reader and tells them
     nothing. -->

## Observation

<!-- What the system does that it shouldn't, or the decision that's owed.
     Behavior first; symbol names are locators, not the subject. -->

## Evidence

<!-- The expensive part to reproduce, so capture it NOW, not later:
     commands run + the relevant output, path/to/file:42 references.
     Date any claim about mutable state (deploy status, live config, DB
     contents) — it's a lead for the next reader, not a standing fact. -->

## Why it matters

<!-- Or why it may not. "This looks alarming and is fine, here's why" is a
     legitimate entry and saves the next person the same investigation. -->

## Approaches considered

<!-- The section a diff can never carry, and the reason old entries stay
     worth reading. For each: what was considered, and why it was rejected
     or deferred. Include the one you'd have reached for first if it's
     wrong — that's the trap you're saving someone from. -->

## Resolution

<!-- Appended when it lands: the PR, or the decision not to act and why.
     Set the status to `fixed` the moment the change ships — the entry stays
     here, in the open directory, because only a human closes it. Closing is
     `.github/scripts/archive-worklog.sh <slug> --apply`, which stamps
     `resolved`, moves the file under archives/ with a YYYY-MM-DD-HHMM- prefix,
     and repoints every citation of it in the repo. Never do that move by
     hand. -->
