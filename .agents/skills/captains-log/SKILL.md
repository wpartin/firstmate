---
name: captains-log
description: >-
  Agent-only procedure for the captain's log, the private Markdown record firstmate renders from its own records.
  Load when the captain asks to turn the log on or off, move it, configure ticket, people, or redaction patterns, or asks where something is in the log, and when answering an inbox note that carries a log_day= line.
user-invocable: false
metadata:
  internal: true
---

# captains-log

The log is a projection of durable records, so firstmate's job is to keep feeding those records, never to write the log by hand.
[`docs/captains-log.md`](../../../docs/captains-log.md) owns the layout and what each record renders as, and `bin/fm-log.sh`'s header owns the commands.

## What keeps the log correct

- Dispatch, worker status, PR-ready, merge, and cleanup already reach the log through their owning scripts.
- A question for the captain reaches the log only as a captain hold: always hold through `bin/fm-captain-hold.sh hold`, never by writing a question into a note.
- The captain's answer reaches the log only as a recorded answer: `bin/fm-send.sh --resolve-key`, `bin/fm-captain-hold.sh answer`, or the board's bound `answers` intake.
  Whatever channel the captain used, record the captain's own words there; the log nests them under the question.
- A new learning reaches the log through `/stow`, which mirrors it with `bin/fm-log.sh learn`.
- Use `bin/fm-log.sh add` only for something the captain explicitly asks to have noted that no record carries.

## Inbox notes from the log

A note whose body carries `log_day=YYYY-MM-DD` was sent from the log.
When it also carries `task=<id>` naming a live captain hold, it is the captain's answer to that hold: record it with `bin/fm-captain-hold.sh answer <id>` using the captain's words from the note, then acknowledge the note.
Otherwise answer it with `bin/fm-inbox.sh reply <id>` so the reply is threaded under the question in the day note, then acknowledge it.

## Turning it on, off, or elsewhere

- `bin/fm-log.sh enable` puts the log in `data/log/`; this is the default and needs no discussion.
- A folder outside the home, such as a cloud-synced Obsidian vault, needs the captain's explicit word for that folder, because everything in the log then syncs to that provider.
  Say so plainly before running `bin/fm-log.sh enable <folder>`.
- `bin/fm-log.sh disable` stops writing and keeps the files.
- Never enable the log in a home the captain did not name.

## Answering "where is it"

`bin/fm-log.sh path` prints the root, the session-start digest prints today's note path, and `bin/fm-log.sh sync` brings the log up to date on demand.
Give the captain the path; do not paste log contents into chat unless asked.
