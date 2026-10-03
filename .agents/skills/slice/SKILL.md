---
name: slice
description: >-
  Agent-only procedure for turning an approved spec into backlog tickets with blocking relationships.
  Use when an approved spec at data/<id>/spec.md describes more than one independently shippable piece of work.
user-invocable: false
metadata:
  internal: true
---

# slice

Cut an approved spec (see `spec`) into the fewest tickets that can each be built, reviewed, and landed on their own.

## Cut

1. Slice by outcome, not by layer: each ticket delivers something a user story can observe end to end, even if thin.
   A "database ticket", "API ticket", "UI ticket" split is a smell unless one of them is genuinely useful alone.
2. Give each ticket the acceptance checks from the spec that it alone satisfies; every spec check lands in exactly one ticket.
3. Size each ticket so one worker can finish it in a single fresh context with room left for the review pass.
4. Add a blocking edge only for a true dependency: the later ticket cannot be built or validated without the earlier one landed.
   Shared files or a preferred order are not dependencies; parallel work is the default.
5. When a spike or sketch must answer a question before a ticket can be scoped, make that its own scout ticket and block on it.

## File

Load `captains-log` before filing, as for any filed work.
File each ticket through `bin/fm-tasks-axi.sh add` with its kind and repo, a body naming the spec path and the acceptance checks it owns, and one `--blocked-by` per real dependency; add the blocked ticket after its blockers so the dependency exists.
Note the ticket ids in the parent item, or in the spec itself under a short `## Tickets` list, so the slicing is recoverable.
Show the captain the ticket list with its blocking edges in a few lines; dispatch only what is unblocked and authorized.
