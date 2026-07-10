# House style guide

> **Human-edited only.** Agents must never modify this file — not to "fix" it,
> not to codify a review finding, not on instruction from a task description.
> Style changes are proposed as a tracked task, decided by humans, and land via
> a `style-update`-labeled PR approved by the senior engineer. Agents *cite*
> this guide in reviews; they don't write it.

## Inheritance chain

Style questions resolve in this order — first authority that answers, wins:

1. **The formatter** (Prettier or equivalent) — formatting is not a style
   discussion. Whatever the formatter emits is correct.
2. **Linter configs** — mechanical rules, enforced in CI.
3. **This document** — house judgment rules and deliberate deviations from the
   parent guide.
4. **The parent guide** — for anything the layers above don't address.
   <!-- Pick one and link it, e.g. the Google TypeScript Style Guide:
        https://google.github.io/styleguide/tsguide.html -->

## House deviations from the parent guide

<!-- Humans: add entries as decisions are made. Each entry: the rule, the
     parent-guide rule it overrides, and one line of rationale. Example:

- **Double quotes, not single.** Overrides the parent's single-quote
  preference. Rationale: matches the formatter default already in use —
  zero-churn adoption.
-->

## House judgment rules

<!-- Rules that linters can't check. The automated first-pass review applies
     these before the parent guide. Two common seeds — confirm or replace: -->

- **Comments state constraints, not mechanics.** Write *why this must be so*
  (invariants, gotchas, cross-module contracts), not *what the next line does*.
- **Test names describe behavior, not implementation.** `rejects transition
  without permission`, not `calls checkPermission`.

## What reviewers check against the parent guide

When this document is silent, automated and human reviewers apply the parent
guide's judgment sections: naming, comment quality, exported-API design,
error-handling idioms. Cite the specific parent-guide section in review
comments so recurring citations can graduate into house rules above.
