#!/usr/bin/env bash
# tests/fm-log-recall.test.sh - recall over the captain's log (bin/fm-log.sh
# index and recall, bin/fm_log.py): golden packs for an exact ticket, a plain
# person name, fuzzy terms, --since, and the bound; an incremental index equals
# a rebuild; redaction hides text from search; --for brief carries no paths;
# a learning filed against a ticket, project, or task comes back for them;
# the log being off exits 3; and a 50k-record ledger answers under 200 ms.
# bin/fm-log.sh's header owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-log-recall)
LOG="$ROOT/bin/fm-log.sh"
export TZ=UTC

# 2026-09-24T09:00:00Z; the day before is 2026-09-23.
T0=1790240400
DAY=86400

make_home() {  # <name>: prints a home with the log, ledger, and ticket pattern on
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'on\n' > "$home/config/log"
  : > "$home/config/fleet-ledger"
  printf '(?i)\\b(ENG-[0-9]+)\\b\thttps://tracker.example/{id}\n' > "$home/config/log-tickets"
  cat > "$home/snapshot.json" <<'EOF'
{"queue":[
  {"id":"eng-12-retry","title":"ENG-12 retry billing calls","repo":"billing","state":"in_flight","hold_bucket":null,"hold_kind":null,"blocked_by":[],"people":["Dana Reyes"]},
  {"id":"pick-colour","title":"Pick a colour","repo":"web","state":"queued","hold_bucket":"live","hold_kind":"captain","hold_reason":"blue or green","blocked_by":[],"people":[]},
  {"id":"old-audit","title":"Audit old exports","repo":"billing","state":"done","blocked_by":[],"people":[]}
 ],
 "in_flight":[{"id":"eng-12-retry","name":"ENG-12 retry billing calls","repo":"billing"}]}
EOF
  printf '%s\n' "$home"
}

run_log() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_LOG_SNAPSHOT_FILE="$home/snapshot.json" \
    FM_LOG_TODAY="${TODAY:-2026-09-25}" "$LOG" "$@"
}

ledger() {  # <home> <json-record...>
  local home=$1
  shift
  printf '%s\n' "$@" >> "$home/state/fleet-ledger.jsonl"
}

eid() { printf '%s' "$1" | shasum | cut -c1-12; }

has() { assert_contains "$1" "$2" "${3:-recall output}"; }
lacks() { assert_not_contains "$1" "$2" "${3:-recall output}"; }

R_OLD='{"v":1,"ts":'"$((T0 - 30 * DAY))"',"event":"task.dispatched","task":"old-audit","kind":"scout","project":"billing","harness":"claude","model":null}'
R_OLD_DONE='{"v":1,"ts":'"$((T0 - 29 * DAY))"',"event":"task.status","task":"old-audit","state":"done","key":null,"text":" exports audited, nothing retried"}'
R_START='{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"eng-12-retry","kind":"ship","project":"billing","harness":"claude","model":null}'
R_WORKING='{"v":1,"ts":'"$((T0 + 30))"',"event":"task.status","task":"eng-12-retry","state":"working","key":null,"text":" setup done"}'
R_HELD='{"v":1,"ts":'"$((T0 + 60))"',"event":"captain.held","task":"eng-12-retry","reason":"retry on 429 or back off?","until":null}'
R_ANSWER='{"v":1,"ts":'"$((T0 + 120))"',"event":"captain.answered","task":"eng-12-retry","mode":"answered","source":null,"words":"retry with jitter, never approach B"}'
R_DONE='{"v":1,"ts":'"$((T0 + 180))"',"event":"task.status","task":"eng-12-retry","state":"done","key":null,"text":" retrying implemented"}'
R_MERGED='{"v":1,"ts":'"$((T0 + 240))"',"event":"task.merged","task":"eng-12-retry","via":"pr","pr":"https://github.com/acme/billing/pull/41"}'
R_COLOUR='{"v":1,"ts":'"$((T0 + 300))"',"event":"captain.held","task":"pick-colour","reason":"blue or green","until":null}'
R_NOTE='{"v":1,"ts":'"$((T0 + 360))"',"event":"inbox.noted","task":null,"note":"n1","log_day":"2026-09-24","thread":null,"text":"log_day=2026-09-24\nprivate musing about ENG-12"}'

fixture() {  # <home>: the standard ledger, synced
  ledger "$1" "$R_OLD" "$R_OLD_DONE" "$R_START" "$R_WORKING" "$R_HELD" "$R_ANSWER" "$R_DONE" "$R_MERGED" "$R_COLOUR" "$R_NOTE"
  run_log "$1" sync >/dev/null 2>&1 || fail "fixture sync failed"
}

test_exact_ticket_golden_pack() {
  local home out day
  home=$(make_home ticket)
  fixture "$home"
  out=$(run_log "$home" recall ENG-12) || fail "recall failed: $out"
  day=2026/09/24/2026-09-24.md
  assert_equals "query: ENG-12
resolved: ticket ENG-12
entities[3]{kind,name,first,last,touches,note}:
  ticket,ENG-12,2026-09-24,2026-09-24,5,tickets/ENG-12.md
  person,Dana Reyes,2026-09-24,2026-09-24,4,people/Dana Reyes.md
  project,billing,2026-08-25,2026-09-24,6,projects/billing.md
timeline[4]{date,what,task,cite}:
  2026-09-24,Noted: private musing about ENG-12,\"\",$day#fm:note:n1
  2026-09-24,Landed https://github.com/acme/billing/pull/41,eng-12-retry,$day#fm:$(eid "$R_MERGED")
  2026-09-24,Finished - retrying implemented,eng-12-retry,$day#fm:$(eid "$R_DONE")
  2026-09-24,Started in billing,eng-12-retry,$day#fm:$(eid "$R_START")
decisions[1]{date,question,answer,state,cite}:
  2026-09-24,retry on 429 or back off?,\"retry with jitter, never approach B\",answered,$day#fm:$(eid "$R_HELD")
open[1]{task,state,since}:
  eng-12-retry,in flight,2026-09-24" "$out" "exact ticket pack"
  lacks "$out" "setup done" "routine progress stays out"
  pass "an exact ticket id resolves to a golden, dated, cited pack"
}

test_plain_person_name_resolves() {
  local home out
  home=$(make_home person)
  fixture "$home"
  out=$(run_log "$home" recall what did we decide with Dana Reyes) || fail "recall failed: $out"
  has "$out" "resolved: person Dana Reyes"
  has "$out" "retry with jitter, never approach B"
  has "$out" "open[1]{task,state,since}:
  eng-12-retry,in flight,2026-09-24"
  out=$(run_log "$home" recall --person "Dana Reyes" --json) || fail "json recall failed"
  has "$out" '"kind": "person"'
  has "$out" '"answer": "retry with jitter, never approach B"'
  pass "a person's plain name in a question becomes an entity filter"
}

test_aliases_and_structured_tickets_resolve() {
  local home out a b
  home=$(make_home aliases)
  printf 'Dana Reyes\tDana, DR\n' > "$home/config/log-people"
  cat > "$home/snapshot.json" <<'EOF'
{"queue":[
  {"id":"eng-12-retry","title":"ENG-12 retry billing calls","repo":"billing","state":"done","blocked_by":[],"people":["Dana Reyes"]},
  {"id":"docs-a","title":"document billing","repo":"billing","state":"done","blocked_by":[],"tickets":[],"people":[]},
  {"id":"docs-b","title":"ENG-5 cleanup","repo":"billing","state":"done","blocked_by":[],"tickets":[],"people":[]}
 ]}
EOF
  ledger "$home" "$R_START" "$R_HELD" "$R_ANSWER" \
    '{"v":1,"ts":'"$((T0 + 400))"',"event":"task.dispatched","task":"docs-b","kind":"ship","project":"billing","harness":"claude","model":null}' \
    '{"v":1,"ts":'"$((T0 + 400))"',"event":"task.dispatched","task":"docs-a","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":["ENG-5","ENG-77"],"people":["DR"]}'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  out=$(run_log "$home" recall what did Dana decide) || fail "alias recall failed: $out"
  has "$out" "resolved: person Dana Reyes"
  has "$out" "retry with jitter, never approach B"
  out=$(run_log "$home" recall --person DR) || fail "alias flag recall failed: $out"
  has "$out" "resolved: person Dana Reyes"
  has "$out" ",docs-a,"
  out=$(run_log "$home" recall ENG-77) || fail "filed ticket recall failed: $out"
  has "$out" "resolved: ticket ENG-77"
  has "$out" ",docs-a,"
  out=$(run_log "$home" recall ENG-5) || fail "mixed ticket recall failed: $out"
  a=$(printf '%s\n' "$out" | grep -n ',docs-a,' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$out" | grep -n ',docs-b,' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "a filed ticket should outrank a title match: $out"
  pass "aliases resolve to their person, filed tickets resolve without the title, and title matches rank lower"
}

test_filed_person_matches_registered_name_case_insensitively() {
  local home out
  home=$(make_home casefold)
  printf 'Dana Reyes\tDR\n' > "$home/config/log-people"
  cat > "$home/snapshot.json" <<'EOF2'
{"queue":[
  {"id":"docs-a","title":"document billing","repo":"billing","state":"done","blocked_by":[],"tickets":[],"people":[]}
 ]}
EOF2
  ledger "$home" \
    '{"v":1,"ts":'"$((T0 + 400))"',"event":"task.dispatched","task":"docs-a","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":[],"people":["dana reyes"]}'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  [ -f "$home/data/log/people/Dana Reyes.md" ] || fail "no canonical person note: $(ls -R "$home/data/log")"
  out=$(run_log "$home" recall --person "Dana Reyes") || fail "person recall failed: $out"
  has "$out" "resolved: person Dana Reyes"
  has "$out" ",docs-a,"
  pass "a filed person in a different case lands on the registered name's note and recall"
}

test_fuzzy_terms_and_misspelled_names() {
  local home out
  home=$(make_home fuzzy)
  fixture "$home"
  out=$(run_log "$home" recall retries) || fail "recall failed"
  lacks "$out" "resolved:"
  has "$out" "Finished - retrying implemented"
  has "$out" "exports audited, nothing retried"
  out=$(run_log "$home" recall Reyse) || fail "misspelled recall failed"
  has "$out" "resolved: person Dana Reyes (near 'Reyse')"
  out=$(run_log "$home" recall zebra) || fail "empty recall failed"
  has "$out" "found: nothing in the log"
  pass "free terms match by stem and prefix, and a misspelled name resolves by trigrams"
}

test_since_filters_older_rows() {
  local home out
  home=$(make_home since)
  fixture "$home"
  out=$(run_log "$home" recall --project billing) || fail "recall failed"
  has "$out" "exports audited"
  out=$(run_log "$home" recall --project billing --since 2026-09-01) || fail "since recall failed"
  lacks "$out" "exports audited"
  has "$out" "Landed https://github.com/acme/billing/pull/41"
  out=$(run_log "$home" recall --project billing --since 3d) || fail "relative since failed"
  lacks "$out" "exports audited"
  pass "--since drops older rows by date or by days"
}

test_bound_and_more_count() {
  local home out i
  home=$(make_home bound)
  for i in $(seq 1 60); do
    ledger "$home" '{"v":1,"ts":'"$((T0 - i * 3600))"',"event":"task.status","task":"eng-12-retry","state":"blocked","key":null,"text":" waiting on vendor round '"$i"'"}'
  done
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  out=$(run_log "$home" recall ENG-12) || fail "recall failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 40 ] || fail "default pack exceeded 40 lines"
  [ "${#out}" -le 2600 ] || fail "default pack exceeded the byte bound: ${#out}"
  has "$out" "more: "
  has "$out" "waiting on vendor round 1,"
  lacks "$out" "waiting on vendor round 60,"
  out=$(run_log "$home" recall ENG-12 --limit 10) || fail "limited recall failed"
  [ "$(printf '%s\n' "$out" | wc -l)" -le 10 ] || fail "--limit 10 exceeded 10 lines"
  has "$out" "more: "
  pass "the pack is bounded, newest first, with a more: count"
}

test_incremental_index_equals_rebuild() {
  local home a b q
  home=$(make_home incremental)
  ledger "$home" "$R_OLD" "$R_OLD_DONE" "$R_START"
  run_log "$home" sync >/dev/null 2>&1 || fail "first sync failed"
  ledger "$home" "$R_WORKING" "$R_HELD"
  run_log "$home" sync >/dev/null 2>&1 || fail "second sync failed"
  run_log "$home" ticket ENG-12 "vendor says 429s are expected on bulk" >/dev/null || fail "ticket failed"
  run_log "$home" add worked "called Dana about the jitter window" >/dev/null || fail "add failed"
  printf '# Retry backoff\n\nJitter beats fixed delays for the billing vendor.\n' \
    | run_log "$home" learn retry-backoff "Retry backoff" >/dev/null || fail "learn failed"
  mkdir -p "$home/data/old-audit"
  printf '# Export audit\n\nNothing in the exports retries twice.\n\n## Detail\n\nsecondparagraphonly\n' > "$home/data/old-audit/report.md"
  ledger "$home" "$R_ANSWER" "$R_DONE" "$R_MERGED" "$R_COLOUR" "$R_NOTE"
  run_log "$home" sync >/dev/null 2>&1 || fail "third sync failed"
  printf -- '- hand note: backoff capped at 30s\n' >> "$home/data/log/tickets/ENG-12.md"
  run_log "$home" sync >/dev/null 2>&1 || fail "fourth sync failed"
  a=''
  for q in "ENG-12" "jitter" "exports" "backoff" "--recent" "--project billing" "Dana Reyes"; do
    # shellcheck disable=SC2086 # Each query is deliberately split into words.
    a="$a$(run_log "$home" recall $q --json --limit 80)"
  done
  has "$a" "vendor says 429s are expected on bulk" "hand-authored ticket line"
  has "$a" "backoff capped at 30s" "unanchored captain line"
  has "$a" "tickets/ENG-12.md#L" "unanchored lines cite their line"
  has "$a" "#fm:manual:" "manual lines cite their anchor"
  has "$a" "\"slug\": \"retry-backoff\"" "learning found by its body"
  has "$a" "Report: Export audit - Nothing in the exports retries twice." "scout report first paragraph"
  lacks "$a" "secondparagraphonly" "report stops at the first paragraph"
  run_log "$home" index --rebuild || fail "rebuild failed"
  b=''
  for q in "ENG-12" "jitter" "exports" "backoff" "--recent" "--project billing" "Dana Reyes"; do
    # shellcheck disable=SC2086 # Each query is deliberately split into words.
    b="$b$(run_log "$home" recall $q --json --limit 80)"
  done
  assert_equals "$a" "$b" "incremental index differs from a rebuild"
  pass "an index kept by sync equals one rebuilt from scratch"
}

test_redaction_hides_text_from_search() {
  local home out
  home=$(make_home redact)
  printf 'hunter[0-9]+\n' > "$home/config/log-redact"
  ledger "$home" "$R_START" \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"task.status","task":"eng-12-retry","state":"blocked","key":null,"text":" password hunter22 rejected"}'
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  out=$(run_log "$home" recall hunter22) || fail "recall failed"
  has "$out" "found: nothing in the log"
  out=$(run_log "$home" recall ENG-12) || fail "ticket recall failed"
  has "$out" "Blocked - password [redacted] rejected"
  lacks "$out" "hunter22"
  pass "config/log-redact applies before indexing"
}

test_brief_has_no_paths_and_never_fails() {
  local home out rc
  home=$(make_home brief)
  fixture "$home"
  out=$(run_log "$home" recall ENG-12 --for brief) || fail "brief recall failed"
  has "$out" "retry with jitter, never approach B"
  lacks "$out" ".md"
  lacks "$out" "#fm:"
  lacks "$out" "private musing" "inbox note text stays out of briefs"
  out=$(run_log "$home" recall zebra --for brief)
  assert_equals "" "$out" "an empty brief pack prints nothing"
  out=$(run_log "$home" recall --for brief --since yesterday 2>&1)
  rc=$?
  assert_equals "0:" "$rc:$out" "a brief caller never sees a failure"
  rm -f "$home/state/.log-index.db"
  out=$(run_log "$home" recall ENG-12 --for brief 2>&1)
  rc=$?
  assert_equals "0:" "$rc:$out" "a missing index prints nothing for a brief"
  out=$(run_log "$home" recall ENG-12 2>&1)
  assert_equals 1 "$?" "a missing index fails a direct caller"
  has "$out" "fm-log.sh index"
  pass "--for brief drops paths and private text and never fails its caller"
}

test_captain_form_keeps_one_cite_per_group() {
  local home out
  home=$(make_home captain)
  fixture "$home"
  out=$(run_log "$home" recall ENG-12 --for captain) || fail "captain recall failed"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^timeline_see: 2026/09/24/2026-09-24.md#fm:')" "one timeline cite"
  assert_equals 3 "$(printf '%s\n' "$out" | grep -c '_see: ')" "one cite each for entities, timeline, and decisions"
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c '#fm:')" "rows carry no cites of their own"
  pass "--for captain keeps one cite per group"
}

test_stale_marker_is_reported() {
  local home out
  home=$(make_home stale)
  fixture "$home"
  rm -f "$home/state/.log-index.db"*
  mkdir "$home/state/.log-index.db"
  ledger "$home" "$R_COLOUR"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync must succeed when only the index fails"
  assert_present "$home/state/.log-index-stale" "stale marker"
  rmdir "$home/state/.log-index.db"
  printf '2026-09-24 10:00\n' > "$home/state/.log-index-stale"
  run_log "$home" index || fail "index failed"
  assert_absent "$home/state/.log-index-stale" "a good update clears the marker"
  printf '2026-09-24 10:00\n' > "$home/state/.log-index-stale"
  out=$(run_log "$home" recall ENG-12) || fail "recall failed"
  has "$out" "stale: index stale since 2026-09-24 10:00"
  pass "a failed index update leaves a marker that recall reports"
}

test_log_off_exits_3_quietly() {
  local home out
  home=$(make_home off)
  fixture "$home"
  printf 'off\n' > "$home/config/log"
  out=$(run_log "$home" recall ENG-12 2>&1)
  assert_equals "3:" "$?:$out" "recall with the log off"
  out=$(run_log "$home" index 2>&1)
  assert_equals "3:" "$?:$out" "index with the log off"
  out=$(run_log "$home" recall ENG-12 --for brief 2>&1)
  assert_equals "3:" "$?:$out" "brief recall with the log off"
  pass "recall and index exit 3 silently when the log is off"
}

test_large_ledger_recall_is_fast() {
  local home best
  home=$(make_home large)
  python3 - "$home/state/fleet-ledger.jsonl" "$T0" <<'EOF'
import json, sys
path, t0 = sys.argv[1], int(sys.argv[2])
with open(path, "w") as fh:
    for i in range(50000):
        task = "eng-%d-work" % (i % 5000)
        ts = t0 - (50000 - i) * 600
        kinds = [
            {"event": "task.dispatched", "kind": "ship", "project": "proj%d" % (i % 40), "harness": "claude", "model": None},
            {"event": "task.status", "state": "done", "key": None, "text": " finished widget %d cleanly" % i},
            {"event": "task.pr_ready", "pr": "https://github.com/acme/p/pull/%d" % i},
            {"event": "captain.held", "reason": "choose option %d" % i, "until": None},
            {"event": "captain.answered", "mode": "answered", "source": None, "words": "go with the second %d" % i},
        ]
        rec = {"v": 1, "ts": ts, "task": task}
        rec.update(kinds[i % 5])
        fh.write(json.dumps(rec) + "\n")
EOF
  printf '{"queue":[]}\n' > "$home/snapshot.json"
  run_log "$home" index --rebuild || fail "large rebuild failed"
  best=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_LOG_TODAY=2026-09-25 python3 - "$LOG" <<'EOF'
import subprocess, sys, time
best = None
for args in (["ENG-4242"], ["ENG-4242"], ["widget", "cleanly"], ["--project", "proj5"], ["ENG-4242"]):
    start = time.monotonic()
    out = subprocess.run([sys.argv[1], "recall"] + args, capture_output=True, text=True)
    took = (time.monotonic() - start) * 1000
    if out.returncode != 0 or "timeline" not in out.stdout:
        sys.exit("recall %s failed: %s %s" % (args, out.stdout, out.stderr))
    if args == ["ENG-4242"]:
        best = took if best is None else min(best, took)
print(int(best))
EOF
) || fail "large recall failed: $best"
  [ "$best" -lt 200 ] || fail "50k-record recall took ${best} ms"
  pass "a 50k-record ledger answers an exact ticket in ${best} ms"
}

test_recent_threads_view() {
  local home out empty
  home=$(make_home threads)
  fixture "$home"
  out=$(run_log "$home" recall --recent --limit 8 --for threads) || fail "threads recall failed: $out"
  assert_equals "open decisions:
  pick-colour: waiting on the captain since 2026-09-24, last touch 2026-09-24
recently touched:
  ticket ENG-12, last touch 2026-09-24
  project web, last touch 2026-09-24
  project billing, last touch 2026-09-24" "$out" "threads view"
  out=$(TODAY=2026-09-24 run_log "$home" recall --recent --for threads)
  lacks "$out" "open decisions" "a decision opened today"
  : > "$home/state/.log-index-stale"
  out=$(run_log "$home" recall --recent --for threads; echo "rc=$?")
  assert_equals "rc=0" "$out" "a stale index prints nothing"
  empty=$(make_home threads-empty)
  run_log "$empty" sync >/dev/null 2>&1
  out=$(run_log "$empty" recall --recent --for threads; echo "rc=$?")
  assert_equals "rc=0" "$out" "an empty index prints nothing"
  out=$(run_log "$TMP_ROOT/nowhere" recall --recent --for threads; echo "rc=$?")
  assert_equals "rc=0" "$out" "a missing home prints nothing"
  pass "recall --for threads shows open decisions and recent entities, and nothing otherwise"
}

test_exact_ticket_golden_pack
test_recent_threads_view

# A decision answered long ago then held again reports the current hold's date.
test_recent_threads_reheld_decision() {
  local home out
  home=$(make_home threads-reheld)
  ledger "$home" \
    '{"v":1,"ts":'"$((T0 - 20 * DAY))"',"event":"captain.held","task":"pick-colour","reason":"red or blue","until":null}' \
    '{"v":1,"ts":'"$((T0 - 20 * DAY + 60))"',"event":"captain.answered","task":"pick-colour","mode":"answered","source":null,"words":"red"}' \
    '{"v":1,"ts":'"$T0"',"event":"captain.held","task":"pick-colour","reason":"blue or green","until":null}'
  run_log "$home" sync >/dev/null 2>&1 || fail "reheld sync failed"
  out=$(run_log "$home" recall --recent --for threads)
  has "$out" "pick-colour: waiting on the captain since 2026-09-24" "re-held decision date"
  lacks "$out" "since 2026-09-04" "re-held decision date"
  out=$(TODAY=2026-09-24 run_log "$home" recall --recent --for threads)
  lacks "$out" "open decisions" "a decision re-held today"
  pass "a re-held decision is dated from its current open hold"
}
test_recent_threads_reheld_decision
test_plain_person_name_resolves
test_aliases_and_structured_tickets_resolve
test_filed_person_matches_registered_name_case_insensitively
test_fuzzy_terms_and_misspelled_names
test_since_filters_older_rows
test_bound_and_more_count
test_incremental_index_equals_rebuild
test_redaction_hides_text_from_search
test_brief_has_no_paths_and_never_fails
test_captain_form_keeps_one_cite_per_group
test_stale_marker_is_reported
test_log_off_exits_3_quietly
test_large_ledger_recall_is_fast

test_entity_export_json() {
  local home out
  home=$(make_home export)
  run_log "$home" export --entities --json >/dev/null 2>&1 && fail "export without an index must fail"
  fixture "$home"
  out=$(run_log "$home" export --entities --json) || fail "export failed: $out"
  out=$(printf '%s' "$out" | jq -c '{version, synced: (.synced | type), task: .tasks["eng-12-retry"], audit: .tasks["old-audit"].project}')
  assert_equals '{"version":1,"synced":"string","task":{"people":[{"last":"2026-09-24","name":"Dana Reyes"}],"project":{"last":"2026-09-24","name":"billing"},"tickets":[{"id":"ENG-12","last":"2026-09-24","url":"https://tracker.example/ENG-12"}]},"audit":{"last":"2026-09-24","name":"billing"}}' "$out" "entity export"
  run_log "$home" export --entities >/dev/null 2>&1; assert_equals 2 "$?" "export needs --json"
  printf 'off\n' > "$home/config/log"
  run_log "$home" export --entities --json >/dev/null 2>&1; assert_equals 3 "$?" "export with the log off"
  pass "the entity export dates each entity by its newest touch across tasks"
}
test_entity_export_json

test_learning_sources_come_back() {
  local home ledger_text a
  home=$(make_home learning-sources)
  fixture "$home"
  printf 'Settlement files arrive after midnight UTC.\n' \
    | run_log "$home" learn settlement-timing "Settlement timing" --ticket eng-77 --project payments >/dev/null \
    || fail "learn with sources failed"
  printf 'Ask for the vendor sandbox before load tests.\n' \
    | run_log "$home" learn vendor-sandbox "Vendor sandbox" --task eng-12-retry >/dev/null || fail "learn with a task failed"
  head -n 6 "$home/data/log/learnings/settlement-timing.md" > "$TMP_ROOT/front"
  assert_equals '---
tasks: []
tickets: ["ENG-77"]
projects: ["payments"]
filed: 2026-09-25
---' "$(cat "$TMP_ROOT/front")" "learning frontmatter"
  ledger_text=$(cat "$home/state/fleet-ledger.jsonl")
  has "$ledger_text" '"slug":"settlement-timing","title":"Settlement timing","sources":{"tickets":["eng-77"],"projects":["payments"]}' "learning sources on the ledger"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  has "$(cat "$home/data/log/tickets/ENG-77.md")" "Learned [[settlement-timing|Settlement timing]]" "ticket note fan-out"
  has "$(cat "$home/data/log/projects/payments.md")" "Learned [[settlement-timing|Settlement timing]]" "project note fan-out"
  a=$(run_log "$home" recall --ticket ENG-77 --for brief)
  has "$a" "Settlement timing" "recall on the ticket brings the learning back"
  lacks "$a" "tasks: []" "frontmatter stays out of recall"
  has "$(run_log "$home" recall --project payments --for brief)" "Settlement timing" "recall on the project"
  has "$(run_log "$home" recall --ticket ENG-12 --for brief)" "Vendor sandbox" "a task's learning comes back for its ticket"
  lacks "$(run_log "$home" recall --ticket ENG-12 --for brief)" "Settlement timing" "an unrelated learning stays out"
  run_log "$home" index --rebuild || fail "rebuild failed"
  has "$(run_log "$home" recall --ticket ENG-77 --for brief)" "Settlement timing" "a rebuilt index keeps the learning's sources"
  pass "a learning filed against a ticket, project, or task comes back for them and fans out to their notes"
}
test_learning_sources_come_back

test_learning_links_follow_every_task_and_refiling() {
  local home
  home=$(make_home learning-refile)
  fixture "$home"
  printf 'Colour tokens live in the billing theme.\n' \
    | run_log "$home" learn colour-tokens "Colour tokens" --task pick-colour --task eng-12-retry >/dev/null \
    || fail "learn with two tasks failed"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  has "$(run_log "$home" recall --ticket ENG-12 --for brief)" "Colour tokens" "the second task's ticket brings the learning back"
  has "$(run_log "$home" recall --project billing --for brief)" "Colour tokens" "the second task's project brings the learning back"
  printf 'Settlement files arrive after midnight UTC.\n' \
    | run_log "$home" learn settlement-timing "Settlement timing" --ticket eng-77 >/dev/null || fail "first filing failed"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  has "$(run_log "$home" recall --ticket ENG-77 --for brief)" "Settlement timing" "first filing recalls on its ticket"
  printf 'Settlement files arrive after midnight UTC.\n' \
    | run_log "$home" learn settlement-timing "Settlement timing" --ticket eng-78 >/dev/null || fail "re-filing failed"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  has "$(run_log "$home" recall --ticket ENG-78 --for brief)" "Settlement timing" "the corrected ticket recalls the learning"
  lacks "$(run_log "$home" recall --ticket ENG-77 --for brief)" "Settlement timing" "the stale ticket no longer recalls it"
  pass "a learning comes back for every task it names, and re-filing replaces stale sources"
}
test_learning_links_follow_every_task_and_refiling

test_path_project_files_under_its_name() {
  local home out
  home=$(make_home path-project)
  ledger "$home" '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"eng-12-retry","kind":"ship","project":"/srv/repos/billing/","harness":"claude","model":null}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"task.status","task":"eng-12-retry","state":"done","key":null,"text":"retries in"}'
  mkdir -p "$home/data/log/projects" "$home/data/log/2026/09/20"
  printf '# /srv/repos/billing\n\n- 2026-09-20 09:00 Started: old work %%%% fm:aaaaaaaaaaaa %%%%\n' > "$home/data/log/projects/-srv-repos-billing-.md"
  printf -- '- 09:00 Started old work in [[-srv-repos-billing-]] %%%% fm:aaaaaaaaaaaa %%%%\n' > "$home/data/log/2026/09/20/2026-09-20.md"
  run_log "$home" sync >/dev/null 2>&1 || fail "sync failed"
  out=$(run_log "$home" recall --project billing --json) || fail "recall failed: $out"
  has "$out" "retries in" "the project name recalls the task"
  lacks "$out" "/srv/repos" "no entity carries the path"
  out=$(cat "$home/data/log/projects/billing.md" 2>/dev/null; grep -rl "srv-repos\|/srv/repos" "$home/data/log" 2>/dev/null)
  has "$out" "retries in" "the task lands in the project's note"
  has "$out" "old work" "the older path-named note merges into it"
  has "$(cat "$home/data/log/2026/09/20/2026-09-20.md")" "[[billing]]" "an older chip now links the project"
  lacks "$out" "srv" "no note or chip names the path"
  pass "a task whose record carries a project path renders and recalls under the project name only"
}
test_path_project_files_under_its_name

