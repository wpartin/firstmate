---
name: align
description: >-
  Get firstmate and the captain on the same page before work starts: a short, pointed intake interview that ends with a one-paragraph shared statement the captain approves.
  Use when the captain invokes /align, and before writing instructions for an ambiguous ask or a design ask whose goal, scope, or success could reasonably be read more than one way.
  Not for verifying finished work; that is qa-plan.
user-invocable: true
metadata:
  internal: true
---

# align

Agree what the work is before anyone spends a worker's context on it.
The output is one approved paragraph, not a document, and the interview stops the moment that paragraph is agreed.

## When to skip

Skip it when the ask is already concrete: a named bug with a clear expected behavior, a small explicit change, or a follow-up whose referent is obvious.
Skip any question the registry, the code, earlier reports, or the captain's log already answers; read those first instead of asking.

## Interview

1. Name the single biggest unknown that would change what gets built, and ask only about that.
2. Ask one question per message, and offer your best guess as the default answer so the captain can reply "yes" or correct it.
3. Prefer concrete choices over open prompts: "A or B?" beats "what do you want?".
4. Push on vague words until they have an observable meaning: "faster" becomes a number, "cleaner" becomes a named behavior, "works" becomes something the captain could click or run.
5. Cover only what is genuinely open among: the goal and who it serves, what is explicitly out of scope, the hard constraints, and how the captain will know it is done.
6. Stop after at most five questions, or earlier once another answer would not change the work.
   If something is still open then, write it into the statement as a stated assumption rather than asking again.

Do not interrogate: no questionnaires, no restating every answer back, and no question whose answer you could look up.

## Shared statement

Write one paragraph in plain words: what will exist when this is done, for whom, the boundary of what it will not do, and how the captain will check it.
End with the assumptions you made, if any, as a short clause.
Ask the captain to approve or correct it, and revise until the captain approves.

## After agreement

The approved paragraph is the captain's ask by reference, so its substance belongs in the instructions' captain's-intent section next to the captain's own words, and it is what the review pass checks against.
Record it in the backlog item's note so it survives a restart.
When the work is large enough to need a problem, solution, stories, decisions, and acceptance checks written down, load `spec` next; otherwise write the instructions directly.
