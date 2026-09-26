# Captain's log

The captain's log is an optional, private, plain-Markdown record of a firstmate home's work: one note per day, the work queue, and notes for tickets, projects, people, and learnings.
It reads well in any editor and is laid out so an Obsidian vault can open it directly.
It is a projection of records firstmate already keeps, so nothing in it depends on firstmate remembering to write it.

`bin/fm-log.sh` is its only writer; its header owns the commands and mechanics.

## Turning it on

The log is off until a home enables it:

```
bin/fm-log.sh enable            # the log lives in data/log/
bin/fm-log.sh enable <folder>   # the whole log lives in <folder> instead
bin/fm-log.sh disable           # stop writing; the files stay
```

`config/log` holds the setting: absent or `off` means off, `on` or an empty line means `data/log/`, and a path means that folder.
Enabling also turns on the [fleet activity ledger](fleet-ledger.md), which the log is rendered from.
The default location sits under `data/`, which is private and gitignored.
A folder outside the home, such as a cloud-synced Obsidian vault, works the same way, but whatever syncs that folder copies every note, so enabling one prints that warning.
Each home's log is its own; second mate homes do not inherit `config/log`, and a folder already claimed by another home (`.fm-log-owner`) is refused.

## Layout

```
queue.md                           the work queue as it stands; overwritten
YYYY/MM/DD/YYYY-MM-DD.md           one note per day, linked as [[YYYY-MM-DD]]
tickets/<ID>.md                    dated lines for one ticket
projects/<name>.md                 dated lines for one project
people/<name>.md                   dated lines for work with one collaborator
learnings/<slug>.md                one durable learning
attachments/                       pasted images and files (captain-owned)
board.html                         the board, rendered for reading offline
README.md                          written once
```

Day notes kept in the older `DD.md` or `DD/log.md` layouts are still read and amended where they are.

## Day notes

The first line links the captain's board: the live board when one is up, otherwise `board.html` beside the log.
Sections, in order:

- **Carried over** - the previous day's Open at close, copied when the day starts.
- **Worked through** - timestamped entries: work started, finished, failed, blocked, needing a decision, ready for review (with the PR's full URL), landed, and learnings filed.
  Routine progress lines are not logged.
- **Asked and answered** - every question held for the captain, with the captain's recorded answer nested beneath it, whichever channel it came through (the board, chat, or an inbox note).
  A deferral shows as "deferred to [[date]]", a released hold as "released the hold", and a call found moot on re-check as "checked: moot".
  An answer whose question is no longer in any note lands on its own day as "re: <title>".
  Inbox notes that carry a `log_day=YYYY-MM-DD` line appear here too, threaded by `thread=<note id>`, with firstmate's reply nested beneath.
- **Open at close** - computed for the current day from the fleet snapshot (waiting on you, blocked, in flight), plus any items added by hand, so a session that ends without a sign-off still leaves an accurate record.

Entries land in the day of the record's own time, so work after midnight belongs to the new day.
Past days are only ever amended, never rewritten.
Text between `%%` marks is a hidden anchor (an Obsidian comment) firstmate uses to place records exactly once; leave it in place.
Worker status text is shortened to one line and stripped of link syntax, and worker reports are never copied in.

## Queue

`queue.md` shows Waiting on you, Blocked, In flight (with the latest activity and any recorded PR), Deferred, Parked, Queued (the first 15), and Done recently, all taken from `bin/fm-bearings-snapshot.sh --json --fields queue`.
When the snapshot cannot be read, the last good view stays and is marked stale.

## Tickets, projects, people, learnings

- **Tickets** link only through `config/log-tickets`: one `<regex><TAB><url template>` per line, where the first capture group (or the whole match) is the ticket id and `{id}` in the template is replaced by it, for example `(?i)\b([A-Z]{2,5}-\d+)\b` followed by a tab and `https://tracker.example/issue/{id}`.
  Without that file nothing is treated as a ticket.
- **Projects** get a note the first time work in them is logged.
- **People** are linked only when a task's body carries a `people: Name, Other Name` line; an optional `config/log-people` allowlist (one name per line) limits which names are linked.
  Names are never guessed from prose.
- **Learnings** are written with `bin/fm-log.sh learn <slug> <title>` (body on stdin), which also links them from the day note.

`config/log-redact` optionally lists regular expressions, one per line, whose matches are replaced with `[redacted]` before anything is written.

## When it renders

- At session start, as part of the startup digest, which prints today's note path.
- After each turn, bounded to a couple of seconds and never blocking supervision.
- On demand with `bin/fm-log.sh sync`.

If the log folder is unreachable, nothing is lost: the ledger keeps every record and the next sync catches up.

## Boundaries

- The log makes no network calls, and workers are never told where it is.
- Firstmate never writes into `attachments/`, and never deletes anything in the log.
- The board is where the captain acts; the log is the record of what happened.
