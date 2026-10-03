---
name: sketch
description: >-
  Get a throwaway prototype or mock in front of the captain to react to before real building starts, keeping any reusable assets for the implementation.
  Use when the captain invokes /sketch, when the agreed work's look, flow, or interaction is still a guess, or when reacting to something concrete would settle a design question faster than more questions.
user-invocable: true
metadata:
  internal: true
---

# sketch

A sketch is cheap evidence for a decision, not a first draft of the product.
It answers one question - what should this look like, or how should this flow - and is then either discarded or mined for assets.

## Dispatch (firstmate)

Firstmate does not build sketches; dispatch one as a scout task.
In its instructions, name the single question the sketch must answer, the two or three variants worth comparing if any, and the time budget: small, fast, and disposable.
Say which assets are worth keeping if the direction is chosen, such as copy, tokens, layout, or a component.

## Build (worker)

1. Use the fastest medium that answers the question: a single static HTML page, a short script, or a stubbed screen in the project's own UI kit when fidelity matters.
2. Match the project's existing design system so the reaction is to the idea, not to unfamiliar styling.
3. Fake data and skip error handling, persistence, and tests; nothing here ships as-is.
4. Put the sketch and any reusable assets under `data/<id>/sketch/` with a two-line README naming what to look at and what is reusable, and point to it from the report.
   Never commit sketch files to the project's default branch.

## React and carry over

Show the captain the sketch, through the visual review surface when available, and record the pick or the corrections as the captain's own words.
The chosen direction feeds `align` or `spec`; a ship task's instructions point at `data/<id>/sketch/` for assets to reuse, and the implementation rebuilds the rest properly.
Load `captain-hold-lifecycle` before treating the review as complete, as for any visual review.
