---
name: spec
description: >-
  Turn an agreed statement of work into a detailed, durable product spec at data/<id>/spec.md: problem, solution, an extensive numbered story list, implementation and testing decisions, out of scope, further notes, and acceptance checks that feed review and the captain's QA plan.
  Use when the captain invokes /spec, or after align when the agreed work is large enough that its stories and acceptance checks should be written down before slicing or dispatch.
user-invocable: true
metadata:
  internal: true
---

# spec

A spec pins agreed intent so every later step - slicing, implementation, review, and the captain's QA - checks against the same lines.
Write it from the captain's approved statement (see `align`), the conversation so far, and the captain's own words, never from a widened goal of your own.
The shape follows Matt Pocock's `to-spec` skill from the mattpocock-skills plugin (MIT licensed); the wording here is paraphrased, with a closing acceptance-checks section added for firstmate.
Synthesize what you already know instead of running a fresh interview; use `align` when the intent itself is still open.

## Where

Write `data/<id>/spec.md` under the active home, where `<id>` is the backlog id of the work, or of the parent item when the spec will be sliced into several tickets.
Firstmate writes it directly; it is private fleet state, not project content.
Link it from the backlog item note so the spec outlives the conversation.

## Process

1. Explore the project's current code to ground the spec in what exists, using its own domain vocabulary and respecting any recorded architecture decisions in the area.
2. Sketch the seams where the work will be tested.
   Prefer existing seams over new ones, and use the highest seam that can observe the behavior.
   When a new seam is unavoidable, propose it as high as it can go; the fewer seams across the codebase the better, and one is the ideal.
3. Confirm the seams with the captain before writing the rest; this is the one question the spec asks that `align` has not.
4. Write the spec in the shape below and show it to the captain.

## Shape

Use these sections in this order.
Depth is the point: a spec is as long as the work needs, with no one-screen limit.

```markdown
# <short title>

## Problem Statement
<the problem from the user's perspective>

## Solution
<the solution from the user's perspective>

## User Stories
<a long numbered list, optionally grouped under short plain labels>
1. As <actor>, I want <feature>, so that <benefit>.

## Implementation Decisions
- <decision>

## Testing Decisions
- <decision>

## Out of Scope
- <things a reasonable reader might assume are included but are not>

## Further Notes
- <anything else a later reader needs>

## Acceptance checks
- [ ] <observable check: an action and the result someone will see>
```

User stories are extensive and cover every aspect of the feature, including the people who operate, maintain, and extend it where relevant.

Implementation decisions record what was decided, such as the modules built or changed, their interfaces, architecture, schema changes, contracts, and specific interactions, plus technical clarifications the captain gave.
Leave out file paths and code snippets, which go stale quickly.
The one exception is a snippet from a prototype that pins a decision more precisely than prose can, such as a state machine, schema, or type shape: inline only its decision-rich part under the relevant decision and note that it came from a prototype.

Testing decisions state what makes a good test (external behavior only, never implementation details), which modules will be tested, the confirmed seams, and prior art for similar tests already in the project.

Acceptance checks are observable outcomes, not implementation steps: each names something to do and what should happen.
Cover every story that matters with a check, with no cap on their number, because `qa-plan`, `slice`, and the review pass rely on this section.
Mark any check that is an assumption rather than something the captain said, so the captain can strike it.

## Approval and use

Show the captain the spec and get a yes or corrections before dispatch; an unapproved spec is only firstmate's proposal.
Once approved, its problem, solution, and acceptance checks are the captain's ask by reference: carry their substance into the instructions' captain's-intent section so the review pass judges the work against them.
Keep implementation choices that came up along the way in the firstmate spec section instead, never in the captain's-intent section.
For more than one independently shippable piece, load `slice`.
When the work is ready, `qa-plan` builds the captain's checklist from the acceptance checks.
