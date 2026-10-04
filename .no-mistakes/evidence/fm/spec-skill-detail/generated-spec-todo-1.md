# Done command and due dates for the todo CLI

## Problem Statement
The todo CLI can only add items and list them. There is no way to mark an item complete, so finished items stay in the list forever. Items also have no due date, so nothing tells the user which items are late. The captain wants to mark items complete and see overdue ones first in `list`.

## Solution
Add a `done` command that marks an item complete by its number. Let `add` take an optional due date. `list` shows overdue, not-yet-done items first, then the remaining items. Existing `add` and `list` usage, and existing `~/.todo` files, keep working unchanged.

## User Stories
Adding items
1. As a user, I want to add an item with a due date, so that the CLI knows when it is late.
2. As a user, I want to add an item with no due date exactly as before, so that my current habits and scripts keep working.
3. As a user, I want a malformed due date rejected with a clear message and a non-zero exit, so that a typo does not silently create an item that is never overdue.
4. As a user, I want a rejected `add` to write nothing, so that bad input leaves no partial item.

Completing items
5. As a user, I want to run `done <number>` to mark that item complete, so that I can track what is finished.
6. As a user, I want `done` to use the same number that `list` shows for the item, so that I act on the item I just saw.
7. As a user, I want `done` with an unknown or non-numeric number to fail with a clear message and a non-zero exit, so that I notice a wrong number.
8. As a user, I want `done` with no number to print a usage message, so that I know what to type.
9. As a user, I want completed items to be visibly marked in `list`, so that I can tell finished from open.
10. As a user, I want running `done` on an already-complete item to be harmless, so that a repeat does not corrupt anything.

Listing and overdue ordering
11. As a user, I want open items whose due date is before today listed first, so that late work is the first thing I see.
12. As a user, I want overdue items ordered by due date, oldest first, so that the most late is at the top.
13. As a user, I want overdue items clearly marked as overdue, so that the reason for their position is clear.
14. As a user, I want an item due today not treated as overdue, so that I am warned only once a date has actually passed.
15. As a user, I want a completed item never treated as overdue, even if its due date has passed, so that finished work does not nag.
16. As a user, I want non-overdue items to keep their original order after the overdue ones, so that the list stays predictable.
17. As a user, I want each item's due date shown in `list`, so that I can see when things are due.
18. As a user, I want an item's number to stay the same regardless of where it appears in `list`, so that `done` never hits the wrong item after reordering.
19. As a user, I want `list` on an empty or missing file to succeed without error, so that a fresh install behaves.

Compatibility and maintenance
20. As a user with an existing `~/.todo` file written by the old CLI, I want those lines read as open items with no due date, so that I do not lose data or have to migrate.
21. As a maintainer, I want the whole behavior exercised through the CLI end to end, so that tests survive internal refactors.
22. As a maintainer, I want the date used for "today" overridable in tests, so that overdue behavior is deterministic. (assumption)

## Implementation Decisions
- The CLI stays a single shell entry point with the subcommands `add`, `list` and `done`.
- Storage stays one line per item in the existing per-user todo file, appended in creation order. An item's number is its line position in that file. Number never depends on display order.
- Each item carries three facts: its text, an optional due date and a done flag. The line format must let the old plain-text lines parse as open items with no due date.
- Due dates are written as `YYYY-MM-DD` and compared as dates against today's local date. (assumption: format)
- Due date is given to `add` as an option, `--due YYYY-MM-DD`, alongside the free-text item. (assumption: flag spelling and position)
- `done` marks the item in place, so its number and position are unchanged. Completed items stay in the file and in `list`. (assumption: they are not removed or hidden)
- `list` prints overdue open items first, sorted by due date ascending, then every other item in file order. Each line keeps the item's own number. Due date, done state and overdue state are visible on the line. (assumption: exact visual markers are left to the implementer, but the output must still contain the item text so existing greps work)
- The date used as "today" defaults to the system date and can be overridden by an environment variable for tests. (assumption: variable name chosen by the implementer)
- Errors go to stderr with a non-zero exit. Successful commands exit zero.

## Testing Decisions
- Good tests run the CLI as a subprocess with an isolated home directory, as the existing test script does, and assert only on stdout, stderr, exit status and the stored result as seen through `list`. They never read the storage format directly.
- Confirmed seam: the CLI invoked end to end, as `test.sh` does. This is the only seam; no unit-level seams are added.
- Prior art: `test.sh` creates a temporary home, runs `add` then `list`, and greps the output. Extend that script, keeping its existing check passing.
- Overdue behavior is tested with fixed dates through the today override, not the real clock.
- Cover: legacy-format file, add with and without due date, bad date, done on valid, invalid, missing and repeated numbers, ordering of overdue before the rest, tie and boundary cases (due today, done and past due).

## Out of Scope
- Un-doing a completion (`undone`), editing or deleting items.
- Hiding completed items, or filters and flags on `list`.
- Natural-language dates ("tomorrow"), times of day, time zones, and recurring items.
- Priorities, tags, or any other new fields.
- Migrating or rewriting existing todo files.
- Changing where the todo file lives.

## Further Notes
- The captain confirmed the seam proposal: test through the CLI end to end.
- `list` currently numbers lines with `nl`. Numbering must stay file-position based once ordering changes, which is why story 18 exists.
- Items starting with text that looks like an option are a risk for `--due` parsing; the implementer should pick a rule and document it in the spec's notes or the usage message.

## Acceptance checks
- [ ] With a fresh home, `add milk` then `list` shows `milk` (existing check still prints `ok`).
- [ ] `add pay rent --due 2026-01-01` succeeds and `list` shows `pay rent` with its due date.
- [ ] `add x --due 2026-13-45` (or `--due soon`) exits non-zero with a message, and `list` afterwards does not show `x`.
- [ ] After adding items 1, 2, 3, `done 2` succeeds, and `list` still shows all three with item 2 marked complete and numbers unchanged.
- [ ] `done 99` and `done abc` each exit non-zero with a message and change nothing; bare `done` prints usage.
- [ ] Running `done 2` a second time exits cleanly and leaves `list` unchanged.
- [ ] With today set to 2026-06-15, an item due 2026-06-01 and an item due 2026-06-10 are listed before an undated item added earlier, the 06-01 one first, and both are marked overdue.
- [ ] With today set to 2026-06-15, an item due 2026-06-15 is not marked overdue and stays in file order.
- [ ] An overdue item that has been marked done is not marked overdue and is not moved to the top.
- [ ] Non-overdue items appear after the overdue ones in their original order.
- [ ] Marking an item done after reordering affects the item whose number `list` printed, not the item at that screen position.
- [ ] A pre-existing todo file of plain lines lists as open, undated items, and `done` works on them.
- [ ] `list` with no todo file exits zero. (assumption: exact output left open)
- [ ] Setting the today override changes which items are overdue without changing the system clock. (assumption)
