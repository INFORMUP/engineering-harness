# <short title: what's wrong, in behavioral terms>

- **Status:** open <!-- open | fixed | resolved | superseded — one bare word, nothing else -->
- **Next action:** <what has to happen next, and whose call it is — prose belongs here, not in the status slot>
- **Found:** <YYYY-MM-DD>, while <what you were actually doing when this surfaced>
- **Escalated:** no <!-- or: <tracker task id> — see "promote by link, not by copy" in CLAUDE.md -->

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
