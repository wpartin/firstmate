---
name: qa-plan
description: >-
  Give the captain a short checklist of exactly what to click or run on finished work and what they should see.
  Use when the captain invokes /qa-plan, and offer it when relaying ready work whose behavior the captain can check by hand.
  Not for agreeing intent before work; that is align.
user-invocable: true
metadata:
  internal: true
---

# qa-plan

A QA plan lets the captain verify finished work in a few minutes without reading the diff.
It checks the outcome against what was agreed, so it comes after the work is ready, never at intake.

## Sources

Build it from what was agreed, not from what the worker says it did: the spec's acceptance checks at `data/<id>/spec.md` when one exists, otherwise the captain's intent in the task's instructions.
Read the ready PR or branch only to learn how to reach each behavior: the command, route, flag, or screen.
Do this as a fresh read rather than asking the implementation worker, whose context is spent; when a step cannot be determined from the change, ask the worker that one question.

## Shape

Keep each item short:

1. **Setup** - the one or two steps to get the change running locally, such as which branch to check out and which command starts it.
2. **Checks** - numbered steps, each one action and its expected result: "Run `X` - you should see `Y`" or "Open Z and click W - the panel shows V".
   Cover every acceptance check once, plus at most two edge cases worth a human eye.
3. **Not covered** - anything the plan cannot check by hand and what covers it instead, such as the automated tests.

Use exact commands, URLs, and labels the captain can copy; never "verify it works".
Send it in chat with the ready work's full URL, or write it to `data/<id>/qa-plan.md` and point to it when it runs long.
