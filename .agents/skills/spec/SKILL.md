---
name: spec
description: >-
  Turn an agreed statement of work into a short, durable product spec at data/<id>/spec.md: goal, user stories, out of scope, and acceptance checks that feed review and the captain's QA plan.
  Use when the captain invokes /spec, or after align when the agreed work is large enough that its stories and acceptance checks should be written down before slicing or dispatch.
user-invocable: true
metadata:
  internal: true
---

# spec

A spec pins agreed intent so every later step - slicing, implementation, review, and the captain's QA - checks against the same few lines.
Write it from the captain's approved statement (see `align`) and the captain's own words, never from a widened goal of your own.

## Where

Write `data/<id>/spec.md` under the active home, where `<id>` is the backlog id of the work, or of the parent item when the spec will be sliced into several tickets.
Firstmate writes it directly; it is private fleet state, not project content.
Link it from the backlog item note so the spec outlives the conversation.

## Shape

Keep it to one screen, using exactly these sections:

```markdown
# <short title>

## Goal
<one or two sentences: what will exist and why it matters>

## User stories
- As <who>, I can <do what>, so that <outcome>.

## Out of scope
- <things a reasonable reader might assume are included but are not>

## Acceptance checks
- [ ] <observable check: an action and the result someone will see>
```

Acceptance checks are observable outcomes, not implementation steps: each names something to do and what should happen.
Aim for three to eight checks; more usually means the spec should be sliced.
Mark any check that is an assumption rather than something the captain said, so the captain can strike it.

## Approval and use

Show the captain the spec and get a yes or corrections before dispatch; an unapproved spec is only firstmate's proposal.
Once approved, its goal and acceptance checks are the captain's ask by reference: carry their substance into the instructions' captain's-intent section so the review pass judges the work against them.
Keep implementation choices that came up along the way in the firstmate spec section instead, never in the spec's acceptance checks.
For more than one independently shippable piece, load `slice`.
When the work is ready, `qa-plan` builds the captain's checklist from these same checks.
