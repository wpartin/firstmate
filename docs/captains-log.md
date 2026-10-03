# Captain's log

The captain's log is an optional, private, plain-Markdown record of a firstmate home's work: one note per day, the work queue, and notes for tickets, projects, people, and learnings.
It reads well in any editor and is laid out so an Obsidian vault can open it directly.
It is a projection of records firstmate already keeps, so nothing in it depends on firstmate remembering to write it.

`bin/fm-log.sh` is its only writer; its header owns the commands and mechanics.

## Turning it on

The log is on by default: a home with no `config/log` logs to `data/log/` from its first locked session start, the main home and every second mate home alike.

```
bin/fm-log.sh enable            # explicit and idempotent: the log lives in data/log/
bin/fm-log.sh enable <folder>   # the whole log lives in <folder> instead
bin/fm-log.sh disable           # stop writing; the files stay
```

`config/log` holds the setting: `off` means off, absent, `on`, or an empty line means `data/log/`, and a path means that folder.
While the log is on, each locked session start (`bin/fm-log.sh start`) creates the [fleet activity ledger](fleet-ledger.md) flag and the log layout when missing, since the log is rendered from the ledger; a read-only session writes nothing, and `off` materializes nothing.
The default location sits under `data/`, which is private and gitignored.
A folder outside the home, such as a cloud-synced Obsidian vault, works the same way, but whatever syncs that folder copies every note, so enabling one prints that warning.
Each home's log is its own; second mate homes do not inherit `config/log` and so take the same default into their own `data/log/`, and a folder already claimed by another home (`.fm-log-owner`) is refused.

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
`bin/fm-bearings-board.sh` records the live board's address in `state/.log-board-url` only after proving its session open, and clears it whenever it finds the session ended, so the link never points at a closed board.
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
Past days are only ever amended, never rewritten, with one repair: a one-time pass (run on the first sync that has a fleet snapshot, and rerun only when its version in [`bin/fm_log.py`](../bin/fm_log.py) changes) restores in place, keeping anchor and position, each firstmate-anchored `…` that sits exactly where an older renderer cut and matches exactly one full text; lines written by hand, cut elsewhere, or matching several texts stay as they are.
Text between `%%` marks is a hidden anchor (an Obsidian comment) firstmate uses to place records exactly once; leave it in place.
Nothing the log records is shortened: task titles, hold reasons, answers, and status notes appear in full, taken from the backlog rows, the ledger, and the snapshot's untruncated in-flight fields rather than the board's shortened display text.
Worker status text is flattened to one line and stripped of link syntax, and worker reports are never copied in.

## Queue

`queue.md` shows Waiting on you, Blocked, In flight (with the latest activity and any recorded PR), Deferred, Parked, Queued (the first 15), and Done recently, all taken from `bin/fm-bearings-snapshot.sh --json --fields queue`.
When the snapshot cannot be read, the last good view stays and is marked stale.

## Tickets, projects, people, learnings

Tickets, projects, and people are captured as structured fields when work is filed, so their notes fill in the same way every time:

```
bin/fm-tasks-axi.sh add eng-1-retry "retry billing calls" --repo billing --ticket ENG-1 --people "Dana Reyes"
```

`--ticket` and `--people` are repeatable and write `ticket: ENG-1` and `people: Dana Reyes` lines into the item's body; `--repo` is the project.
The dispatch record carries those fields forward, so the task's start, findings, decisions asked and answered, PR, and landing each add one line of the same shape, `<date time> <what>: <title> - <detail>`, to every ticket, project, and person note it names.
A task filed without the fields keeps the older behavior: tickets come from its title or id through the patterns below, and those inferred matches count for less in recall.

- **Tickets** link through `config/log-tickets`: one `<regex><TAB><url template>` per line, where the first capture group (or the whole match) is the ticket id and `{id}` in the template is replaced by it, for example `(?i)\b([A-Z]{2,5}-\d+)\b` followed by a tab and `https://tracker.example/issue/{id}`.
  Without that file only `ticket:` fields are treated as tickets.
- **Projects** get a note the first time work in them is logged.
- **People** are linked only from a task's `people:` field; names are never taken from prose.
  An optional `config/log-people` lists who may be linked, one person per line as `Name` or `Name<TAB>alias, alias`; a listed name or alias, in any letter case, resolves to its listed spelling in notes and recall.
- **Learnings** are written with `bin/fm-log.sh learn <slug> <title>` (body on stdin), which also links them from the day note.
  `--task`, `--ticket`, and `--project` (each repeatable) name the work a learning came from: the note opens with `tasks`, `tickets`, `projects`, and `filed` frontmatter, each named ticket and project note gets a `<date time> Learned [[<slug>|<title>]]` line, and recall returns the learning for those tickets and projects and for the named tasks' own tickets and project, so it comes back in the next brief on the same work.
  Re-filing the same slug replaces its sources, so recall stops returning it for work the new frontmatter no longer names.
  The learning notes are the home's one learnings store: every note also carries `filed`, `status` (`in-force`, `aging`, or `archived`), `tier` (absent means `normal`; `pinned` never decays, `perishable` is stale after 7 days, `normal` after 30; `bin/fm-log.sh stale` lists the lapsed ones), and `reinforced` frontmatter, `bin/fm-log.sh mark` changes the status without touching the text (a pinned note stays in force, and `learn --status` refuses to age or archive it too), and the session-start digest prints only a bounded view of the notes in force (`bin/fm-log.sh learnings`).
  Archived notes stay in the log and in recall.
  The locked session start imports any legacy `data/learnings.md` and `data/memory-archive.md` entries once, as `legacy-<hash>` notes, and leaves those files untouched.

At intake, `bin/fm-log.sh entities "<the captain's words>"` suggests configured ticket ids and listed names or aliases that appear verbatim in the words.
It records nothing: firstmate decides whether to pass them as `--ticket` or `--people`.

`config/log-redact` optionally lists regular expressions, one per line, whose matches are replaced with `[redacted]` before anything is written.
A project is always named by its basename, so a task whose record carries a local project path files under the project's name, and the first sync after this rule arrived merges any older path-named project note and link into it.

## Recall

`bin/fm-log.sh recall` is how firstmate looks things up in the log: by ticket, project, person, or task, or by free terms.

```
bin/fm-log.sh recall ENG-12                          # a ticket named in a question resolves exactly
bin/fm-log.sh recall what did we decide with Dana Reyes
bin/fm-log.sh recall --project billing --since 30d
bin/fm-log.sh recall --recent                        # the last week, plus everything still open
```

It returns one bounded pack, newest and most relevant first: the entities involved with when each was first and last touched, a dated timeline of outcomes, the decisions with the captain's recorded words, learnings, and the items still open.
Every line carries its date and a citation to the note it came from (`<note path>#<anchor>`), so a line can be quoted precisely and opened in the note.
Anything left out by the bound is counted on a `more:` line.
Ticket ids, task ids, registered projects, and people (including `config/log-people` aliases) are matched exactly and shown on a `resolved:` line; the rest of the question is searched as text.

Recall reads a derived index at `state/.log-index.db`, which each sync keeps current from the fleet ledger, the notes (including lines the captain wrote by hand), and the first paragraph of each scout report, storing every text in full.
The index is disposable: `bin/fm-log.sh index --rebuild` recreates it, and redacted text never reaches it.
Emptying the fleet ledger keeps the rows already indexed from it, but a rebuild after that recovers only what the ledger still holds.
The form given to workers (`--for brief`) carries no note paths and no inbox-note or people-note text.
`bin/fm-log.sh`'s header owns the flags, ranking, and output shape.

### Recall at the contract points

Firstmate sees relevant history at the moments it acts, without having to remember to look.

- **Worker instructions:** `bin/fm-brief.sh` first brings the index up to date (waiting at most ten seconds for the log lock), then recalls only what shares a key with the task - its id, a ticket, or a person, never the project alone - in the worker form and writes at most 15 lines under `## Relevant history`, after `## Firstmate spec` and labelled as firstmate-supplied context, never as the captain's intent.
  Nothing is written when the history is empty, the log is off, or recall fails, and the scaffold never fails because of it.
- **Filing work:** after a successful `bin/fm-tasks-axi.sh add`, a `RELATED:` pack follows when the item has a ticket or person field or its title names a known ticket or person, never a project alone; it is silent otherwise, when the log is off, and with `--json`.
- **Session start:** the startup digest prints a `RECENT THREADS` block after today's note path, from `bin/fm-log.sh recall --recent --limit 8 --for threads`: captain decisions whose current unanswered hold opened before today, with their last touch, then the 5 most recently touched tickets and projects.
  It is at most 10 lines and 1 KB, prints nothing when the log is off or its index is empty, stale, or unreadable, and never delays or fails the digest; `bin/fm-startup-memory-budget.sh report` shows it on a separate informational line outside the startup-memory budget.
- **Bearings:** `bin/fm-log.sh export --entities --json` gives each task's tickets, project, and people with the date each was last touched across all work; the Bearings board shows them as small chips on each row, and the `/bearings` chat digest adds them to the end of Captain's Call and Underway lines.
  An absent or failing export only means no chips.
- **Questions about the past and bug scoping:** the `captains-log` and `diagnostic-reasoning` skills run recall before answering or diagnosing.
- **The captain's message:** `bin/fm-log-prompt-hook.sh` runs `bin/fm-log.sh recall --mentions <message> --for captain` and adds the pack to the turn only when the message names an exact configured ticket id, a logged task id, or a `config/log-people` name or alias.
  A message naming none of those adds nothing, and so do the log being off, an empty or unreadable index, a failing recall, and a recall slower than its 3-second bound; the prompt is never blocked.
  That one script is the core for every harness, and each wiring only carries the message in and the pack out:

  | Primary harness | Wiring | Status |
  | --- | --- | --- |
  | Claude | `UserPromptSubmit` hook in `.claude/settings.json` | Wired |
  | Codex | `UserPromptSubmit` hook in `.codex/hooks.json`, behind Codex's hook-trust review | Wired |
  | Pi, pi-signed | `before_agent_start` in `.pi/extensions/fm-primary-turnend-guard.ts`, returned as a hidden context message | Wired |
  | omp | `before_agent_start` in `.omp/extensions/fm-primary-turnend-guard.ts`, as Pi | Wired |
  | Cursor | `beforeSubmitPrompt` can only allow or block the prompt, not add context | Unsupported |
  | Grok | its hooks cannot carry hook output into model context (the nudge tier in [`sessionstart-nudge.md`](sessionstart-nudge.md)) | Unsupported |
  | OpenCode | no verified prompt-time context channel in the tracked plugins | Unsupported |
  | Kimi | not wired as a primary hook surface | Unsupported |

  On an unsupported harness the `captains-log` skill trigger carries the same questions.
  Claude is live-verified; Codex, Pi, pi-signed, and omp are verified only by the portable `tests/fm-log-prompt-hook.test.sh` until `tests/fm-log-prompt-hook-live-e2e.test.sh` runs where they are installed.
  The portable test pins the core and every wiring's handler, and the live guard proves each installed wired harness end to end ([`verification/runtime-backends.md`](verification/runtime-backends.md) "Captain's log prompt history").

## When it renders

- At session start, as part of the startup digest, which prints today's note path and the `RECENT THREADS` block.
- After each turn, bounded to a couple of seconds and never blocking supervision.
- On demand with `bin/fm-log.sh sync`.

If the log folder is unreachable, nothing is lost: the ledger keeps every record and the next sync catches up.

## Boundaries

- The log and recall make no network calls, and workers are never told where it is.
- Firstmate never writes into `attachments/`, and never deletes anything in the log.
- The board is where the captain acts; the log is the record of what happened.
