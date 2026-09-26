#!/usr/bin/env bash
# tests/fm-log.test.sh - the captain's log (bin/fm-log.sh, bin/fm_log.py):
# fixture ledgers and snapshots render golden day notes and queue views,
# replays are no-ops, entries split at midnight, carried-over seeding, answers
# placed under their hold, tickets only from configured patterns, and the
# unreachable-location and foreign-owner refusals. docs/captains-log.md owns
# the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-log)
LOG="$ROOT/bin/fm-log.sh"
export TZ=UTC

make_home() {  # <name>: prints the home; the log and ledger start enabled
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'on\n' > "$home/config/log"
  : > "$home/config/fleet-ledger"
  printf '%s\n' "$home"
}

run_log() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_LOG_SNAPSHOT_FILE="${SNAPSHOT:-$home/snapshot.json}" \
    FM_LOG_TODAY="${TODAY:-2026-09-24}" "$LOG" "$@"
}

ledger() {  # <home> <json-record...>
  local home=$1
  shift
  printf '%s\n' "$@" >> "$home/state/fleet-ledger.jsonl"
}

# 2026-09-24T09:00:00Z and friends.
T0=1790240400

snapshot() {  # <home>
  cat > "$1/snapshot.json" <<'EOF'
{"schema":"fm-bearings.v1",
 "in_flight":[{"id":"fix-login","kind":"ship","state":"working","repo":"web","name":"ABC-12 fix login","doing":"writing the test"}],
 "recorded_prs":[{"id":"fix-login","url":"https://github.com/acme/web/pull/7"}],
 "queue":[
  {"id":"fix-login","title":"ABC-12 fix login","repo":"web","state":"in_flight","hold_bucket":null,"hold_kind":null,"hold_reason":null,"hold_until":null,"blocked_by":[],"pr_url":null,"done":null,"people":["Sam Example"]},
  {"id":"pick-colour","title":"Pick a colour","repo":"web","state":"queued","hold_bucket":"live","hold_kind":"captain","hold_reason":"blue or green","hold_until":null,"blocked_by":[],"pr_url":null,"done":null,"people":[]},
  {"id":"later","title":"Later call","repo":"web","state":"queued","hold_bucket":"dated","hold_kind":"captain","hold_reason":"revisit","hold_until":"2027-01-01","blocked_by":[],"pr_url":null,"done":null,"people":[]},
  {"id":"b1","title":"Blocked one","repo":"web","state":"queued","hold_bucket":null,"hold_kind":null,"hold_reason":null,"hold_until":null,"blocked_by":["q2"],"pr_url":null,"done":null,"people":[]},
  {"id":"p1","title":"Parked one","repo":"web","state":"queued","hold_bucket":null,"hold_kind":null,"hold_reason":"waiting on vendor","hold_until":null,"blocked_by":[],"pr_url":null,"done":null,"people":[]},
  {"id":"q2","title":"Queued thing","repo":"web","state":"queued","hold_bucket":null,"hold_kind":null,"hold_reason":null,"hold_until":null,"blocked_by":[],"pr_url":null,"done":null,"people":[]},
  {"id":"old","title":"Old work","repo":"web","state":"done","hold_bucket":null,"hold_kind":null,"hold_reason":null,"hold_until":null,"blocked_by":[],"pr_url":"https://github.com/acme/web/pull/3","done":"2026-09-20","people":[]}
 ]}
EOF
}

has() { assert_contains "$1" "$2" "${3:-log content}"; }
lacks() { assert_not_contains "$1" "$2" "${3:-log content}"; }

day_note() { printf '%s/data/log/%s/%s/%s/%s.md' "$1" "${2:0:4}" "${2:5:2}" "${2:8:2}" "$2"; }

test_events_render_golden_day_note_and_replay_is_a_noop() {
  local home note first
  home=$(make_home golden)
  snapshot "$home"
  printf '(?i)\\b(ABC-[0-9]+)\\b\thttps://tracker.example/issue/{id}\n' > "$home/config/log-tickets"
  ledger "$home" \
    '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"fix-login","kind":"ship","project":"web","harness":"claude","model":null}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"task.status","task":"fix-login","state":"working","key":null,"text":" setup done"}' \
    '{"v":1,"ts":'"$((T0 + 120))"',"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR [[x]] %% ok"}' \
    '{"v":1,"ts":'"$((T0 + 180))"',"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/web/pull/7"}' \
    '{"v":1,"ts":'"$((T0 + 240))"',"event":"captain.held","task":"pick-colour","reason":"blue or green","until":null}' \
    '{"v":1,"ts":'"$((T0 + 300))"',"event":"captain.answered","task":"pick-colour","mode":"answered","source":"the fleet board","words":"green"}' \
    '{"v":1,"ts":'"$((T0 + 360))"',"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/web/pull/7"}' \
    '{"v":1,"ts":'"$((T0 + 420))"',"event":"some.future","task":"x"}'
  run_log "$home" sync > "$home/out" 2>&1 || fail "sync failed: $(cat "$home/out")"
  note=$(day_note "$home" 2026-09-24)
  assert_equals "$note" "$(cat "$home/out")" "sync prints today's note"
  assert_equals "[Captain's board](file://$home/data/log/board.html)

## Carried over

- (nothing carried over)

## Worked through

- 09:00 Started [[ABC-12]] fix login in [[web]] with [[Sam Example]] %% fm:$(printf '%s' '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"fix-login","kind":"ship","project":"web","harness":"claude","model":null}' | shasum | cut -c1-12) %%
- 09:02 Finished: [[ABC-12]] fix login - PR [x] % ok %% fm:$(printf '%s' '{"v":1,"ts":'"$((T0 + 120))"',"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR [[x]] %% ok"}' | shasum | cut -c1-12) %%" "$(sed -n '1,10p' "$note")" "golden day note head"
  has "$(cat "$note")" "- 09:03 Ready for review: [[ABC-12]] fix login https://github.com/acme/web/pull/7 %% fm:"
  has "$(cat "$note")" "- 09:06 Landed [[ABC-12]] fix login https://github.com/acme/web/pull/7 %% fm:"
  has "$(cat "$note")" "- Pick a colour: blue or green %% fm:hold:pick-colour %%"
  has "$(cat "$note")" "  - Captain via the fleet board: green %% fm:"
  lacks "$(cat "$note")" "setup done"
  has "$(cat "$note")" "## Open at close

- Waiting on you: Pick a colour
- Blocked: Blocked one (by q2)
- In flight: [[ABC-12]] fix login"
  assert_present "$home/data/log/tickets/ABC-12.md" "ticket note"
  has "$(cat "$home/data/log/tickets/ABC-12.md")" "[Open in the tracker](https://tracker.example/issue/ABC-12)"
  assert_present "$home/data/log/projects/web.md" "project note"
  assert_present "$home/data/log/people/Sam Example.md" "people note"
  first=$(cd "$home/data/log" && find . -type f -name '*.md' -exec cat {} +)
  run_log "$home" sync >/dev/null 2>&1 || fail "second sync failed"
  : > "$home/state/.log-cursor"
  run_log "$home" sync >/dev/null 2>&1 || fail "replay sync failed"
  assert_equals "$first" "$(cd "$home/data/log" && find . -type f -name '*.md' -exec cat {} +)" "replay changed the log"
  pass "ledger records render a golden day note, side notes, and replay is a no-op"
}

test_queue_view_renders_from_the_snapshot() {
  local home
  home=$(make_home queue)
  snapshot "$home"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  assert_equals "## Waiting on you (1)

- Pick a colour
  blue or green

## Blocked (1)

- Blocked one
  blocked by q2

## In flight (1)

- ABC-12 fix login
  writing the test https://github.com/acme/web/pull/7

## Deferred (1)

- until [[2027-01-01]]: Later call

## Parked (1)

- Parked one
  waiting on vendor

## Queued (1)

- Queued thing

## Done recently (1)

- Old work https://github.com/acme/web/pull/3" "$(sed -n '5,$p' "$home/data/log/queue.md" | sed '$d')" "golden queue.md"
  rm -f "$home/snapshot.json"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync without a snapshot failed"
  has "$(cat "$home/data/log/queue.md")" "> Stale since "
  has "$(cat "$home/data/log/queue.md")" "- Pick a colour"
  pass "queue.md renders every bucket from the snapshot and keeps the last good view when it fails"
}

test_log_never_reads_the_backlog_file() {
  local home
  home=$(make_home no-backlog)
  snapshot "$home"
  printf -- '- [ ] secret-row - A row only the backlog file knows\n' > "$home/data/backlog.md"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  if grep -rq 'secret-row' "$home/data/log"; then
    fail "the log rendered a row straight from data/backlog.md"
  fi
  pass "the log reads the fleet snapshot, never data/backlog.md"
}

test_midnight_split_and_carried_over_seed() {
  local home
  home=$(make_home midnight)
  snapshot "$home"
  ledger "$home" \
    '{"v":1,"ts":1790294340,"event":"task.status","task":"fix-login","state":"blocked","key":null,"text":" need creds"}' \
    '{"v":1,"ts":1790294460,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" all good"}'
  TODAY=2026-09-24 run_log "$home" sync >/dev/null 2>&1 || fail "first sync failed"
  TODAY=2026-09-25 run_log "$home" sync >/dev/null 2>&1 || fail "second sync failed"
  has "$(cat "$(day_note "$home" 2026-09-24)")" "23:59 Blocked: ABC-12 fix login - need creds"
  lacks "$(cat "$(day_note "$home" 2026-09-24)")" "all good"
  has "$(cat "$(day_note "$home" 2026-09-25)")" "00:01 Finished: ABC-12 fix login - all good"
  has "$(cat "$(day_note "$home" 2026-09-25)")" "## Carried over

- Waiting on you: Pick a colour
- Blocked: Blocked one (by q2)"
  pass "records split at midnight and a new day carries the previous Open at close"
}

test_answers_nest_under_their_hold_across_days() {
  local home note
  home=$(make_home answers)
  snapshot "$home"
  ledger "$home" \
    '{"v":1,"ts":'"$T0"',"event":"captain.held","task":"later","reason":"revisit","until":"2027-01-01"}' \
    '{"v":1,"ts":'"$((T0 + 86400))"',"event":"captain.answered","task":"later","mode":"released","source":null,"words":"go ahead"}' \
    '{"v":1,"ts":'"$((T0 + 86460))"',"event":"captain.answered","task":"b1","mode":"reconciled","source":null,"words":"already landed"}'
  TODAY=2026-09-25 run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  note=$(day_note "$home" 2026-09-24)
  has "$(cat "$note")" "- Later call: revisit %% fm:hold:later %%"
  has "$(cat "$note")" "  - deferred to [[2027-01-01]]
  - Captain (released the hold): go ahead %% fm:"
  has "$(cat "$(day_note "$home" 2026-09-25)")" "- re: Blocked one
  - checked: moot - already landed %% fm:"
  pass "answers nest under their hold on its own day; an unanchored answer lands on its day as re:"
}

test_inbox_threads_render_only_with_a_log_day() {
  local home note
  home=$(make_home inbox)
  snapshot "$home"
  ledger "$home" \
    '{"v":1,"ts":'"$T0"',"event":"inbox.noted","task":null,"note":"n1","log_day":"2026-09-24","thread":null,"text":"log_day=2026-09-24\nShould we pin the linter?"}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"inbox.noted","task":null,"note":"n2","log_day":"2026-09-24","thread":"n1","text":"log_day=2026-09-24\nthread=n1\nAnd the formatter?"}' \
    '{"v":1,"ts":'"$((T0 + 120))"',"event":"inbox.replied","task":null,"note":"n2","text":"Both are pinned now."}' \
    '{"v":1,"ts":'"$((T0 + 180))"',"event":"inbox.noted","task":null,"note":"n3","log_day":null,"thread":null,"text":"just chat"}'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  note=$(day_note "$home" 2026-09-24)
  has "$(cat "$note")" "- Should we pin the linter? %% fm:note:n1 %%
  - And the formatter? %% fm:note:n2 %%
    - firstmate: Both are pinned now. %% fm:"
  lacks "$(cat "$note")" "just chat"
  pass "inbox notes with a log day thread under each other and carry firstmate's reply"
}

test_no_ticket_patterns_means_no_ticket_links() {
  local home
  home=$(make_home no-tickets)
  snapshot "$home"
  ledger "$home" '{"v":1,"ts":'"$T0"',"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/web/pull/7"}'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  assert_absent "$home/data/log/tickets/ABC-12.md" "a ticket note without a configured pattern"
  lacks "$(cat "$(day_note "$home" 2026-09-24)")" "[[ABC-12]]"
  pass "without config/log-tickets nothing is linked as a ticket"
}

test_manual_add_learn_and_unresolved() {
  local home note
  home=$(make_home manual)
  snapshot "$home"
  run_log "$home" add open "Chase the vendor" >/dev/null || fail "add failed"
  run_log "$home" add open "Chase the vendor" >/dev/null || fail "repeated add failed"
  printf 'Bounded waits beat hangs.\n' | run_log "$home" learn bounded-waits "Keep waits bounded" >/dev/null \
    || fail "learn failed"
  assert_equals "# Keep waits bounded

Bounded waits beat hangs." "$(cat "$home/data/log/learnings/bounded-waits.md")" "learning note"
  has "$(cat "$home/state/fleet-ledger.jsonl")" '"event":"learning.filed","task":null,"slug":"bounded-waits","title":"Keep waits bounded"'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  note=$(day_note "$home" 2026-09-24)
  assert_equals 1 "$(grep -c 'Chase the vendor' "$note")" "manual add is idempotent"
  # The learning record carries the real clock's time, so it may land on another day's note.
  grep -rqF "Learned [[bounded-waits|Keep waits bounded]]" "$home/data/log" \
    || fail "the filed learning is not linked from a day note"
  assert_equals "" "$(run_log "$home" unresolved)" "every link resolves"
  pass "manual add is idempotent, learn files a note and a ledger record, unresolved finds nothing missing"
}

test_off_unreachable_and_foreign_owner_refuse() {
  local home rc
  home=$(make_home refusals)
  snapshot "$home"
  rm -f "$home/config/log"
  run_log "$home" sync >/dev/null 2>&1; rc=$?
  assert_equals 3 "$rc" "sync with the log off"
  run_log "$home" sync --quiet; rc=$?
  assert_equals 0 "$rc" "quiet sync with the log off"
  assert_absent "$home/data/log" "the log off still created a folder"
  printf '%s\n' "$home/blocked-parent/log" > "$home/config/log"
  : > "$home/blocked-parent"
  ledger "$home" '{"v":1,"ts":'"$T0"',"event":"task.merged","task":"fix-login","via":"local"}'
  run_log "$home" sync >/dev/null 2>&1; rc=$?
  assert_equals 4 "$rc" "sync to an unreachable location"
  assert_present "$home/state/.log-pending" "pending marker"
  assert_absent "$home/state/.log-cursor" "cursor advanced past an unrendered record"
  mkdir -p "$home/other-log"
  printf '/some/other/home\n' > "$home/other-log/.fm-log-owner"
  printf '%s\n' "$home/other-log" > "$home/config/log"
  run_log "$home" sync >/dev/null 2>"$home/owner.err"; rc=$?
  assert_equals 4 "$rc" "sync into another home's log"
  has "$(cat "$home/owner.err")" "belongs to another firstmate home"
  printf 'on\n' > "$home/config/log"
  run_log "$home" sync >/dev/null 2>&1 || fail "recovery sync failed"
  assert_absent "$home/state/.log-pending" "pending marker after recovery"
  has "$(cat "$(day_note "$home" 2026-09-24)")" "Landed ABC-12 fix login on the local branch"
  pass "the log refuses when off, unreachable, or owned by another home, and replays afterwards"
}

test_enable_turns_on_the_ledger_and_lays_out_the_log() {
  local home root
  home="$TMP_ROOT/enable"
  mkdir -p "$home/state" "$home/data" "$home/config"
  snapshot "$home"
  root=$(run_log "$home" enable 2>/dev/null) || fail "enable failed"
  assert_equals "$home/data/log" "$root" "default root"
  assert_present "$home/config/fleet-ledger" "enable turns on the ledger"
  for d in tickets projects people learnings attachments; do
    [ -d "$root/$d" ] || fail "enable did not create $d/"
  done
  assert_present "$root/README.md" "README"
  assert_present "$(day_note "$home" 2026-09-24)" "today's note"
  run_log "$home" enable "$TMP_ROOT/enable-elsewhere" >/dev/null 2>"$home/enable.err" || fail "enable elsewhere failed"
  has "$(cat "$home/enable.err")" "outside this home"
  assert_equals "$TMP_ROOT/enable-elsewhere" "$(run_log "$home" path)" "configured root"
  pass "enable turns on the ledger, lays out the log, and warns about a location outside the home"
}


test_wait_bounds_a_non_quiet_sync() {
  local home holder start elapsed rc i
  home=$(make_home wait-bound)
  snapshot "$home"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; sleep 30' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.log.lock" "$home/held" &
  holder=$!
  i=0
  while [ ! -e "$home/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$home/held" ] || { kill "$holder" 2>/dev/null; fail "the fixture could not hold the log lock"; }
  start=$(date +%s)
  run_log "$home" sync --wait 1 >/dev/null 2>"$home/wait.err"; rc=$?
  elapsed=$(( $(date +%s) - start ))
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_equals 1 "$rc" "a sync that cannot take the lock"
  has "$(cat "$home/wait.err")" "another log sync is running"
  [ "$elapsed" -lt 6 ] || fail "sync --wait 1 waited ${elapsed}s for a held lock"
  pass "--wait bounds a non-quiet sync's wait for a held lock"
}

test_events_render_golden_day_note_and_replay_is_a_noop
test_queue_view_renders_from_the_snapshot
test_log_never_reads_the_backlog_file
test_midnight_split_and_carried_over_seed
test_answers_nest_under_their_hold_across_days
test_inbox_threads_render_only_with_a_log_day
test_no_ticket_patterns_means_no_ticket_links
test_manual_add_learn_and_unresolved
test_off_unreachable_and_foreign_owner_refuse
test_enable_turns_on_the_ledger_and_lays_out_the_log
test_wait_bounds_a_non_quiet_sync
