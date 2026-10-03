#!/usr/bin/env bash
# tests/fm-log-contract-points.test.sh - recall where firstmate writes: a brief
# scaffolded for a task with prior history carries a path-free `## Relevant
# history` section, an empty history or an off log adds nothing, and
# history keys only on the task id, tickets, and people, never a project alone,
# and bin/fm-tasks-axi.sh add prints RELATED: only when those keys resolve.
# docs/captains-log.md "Recall at the contract points" owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-log-contract-points)
export TZ=UTC
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
command -v tasks-axi >/dev/null 2>&1 || { pass "SKIP: tasks-axi not installed"; exit 0; }

T0=1790240400

make_home() {  # <name> [off]: prints a home whose log holds one landed ENG-12 task
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "${2:-on}" > "$home/config/log"
  : > "$home/config/fleet-ledger"
  printf '(?i)\\b(ENG-[0-9]+)\\b\thttps://tracker.example/{id}\n' > "$home/config/log-tickets"
  printf 'Dana Reyes\n' > "$home/config/log-people"
  cat > "$home/snapshot.json" <<'JSON'
{"queue":[{"id":"eng-12-retry","title":"ENG-12 retry billing calls","repo":"billing","state":"done","blocked_by":[],"people":["Dana Reyes"]}],"in_flight":[]}
JSON
  printf '%s\n' \
    '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"eng-12-retry","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":["ENG-12"],"people":["Dana Reyes"]}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"captain.held","task":"eng-12-retry","reason":"retry on 429 or back off?","until":null}' \
    '{"v":1,"ts":'"$((T0 + 120))"',"event":"captain.answered","task":"eng-12-retry","mode":"answered","source":null,"words":"retry with jitter, never approach B"}' \
    '{"v":1,"ts":'"$((T0 + 240))"',"event":"task.merged","task":"eng-12-retry","via":"pr","pr":"https://github.com/acme/billing/pull/41"}' \
    > "$home/state/fleet-ledger.jsonl"
  [ "${2:-on}" = off ] || in_home "$home" "$ROOT/bin/fm-log.sh" sync >/dev/null 2>&1 || fail "fixture sync failed"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_LOG_SNAPSHOT_FILE="$home/snapshot.json" \
    FM_LOG_TODAY=2026-09-25 "$@"
}

brief_for() {  # <home> <id> <repo>: scaffolds a ship brief and prints it
  in_home "$1" "$ROOT/bin/fm-brief.sh" "$2" "$3" --mode no-mistakes >/dev/null 2>&1 || fail "brief scaffold failed"
  cat "$1/data/$2/brief.md"
}

test_brief_carries_path_free_history() {
  local home out section
  home=$(make_home history)
  in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add eng-12-followup "Follow up on retries" --repo billing --ticket ENG-12 >/dev/null 2>&1 \
    || fail "add failed"
  out=$(brief_for "$home" eng-12-followup billing)
  assert_contains "$out" "## Relevant history" "brief"
  assert_contains "$out" "retry with jitter, never approach B" "the captain's decision reaches the worker"
  section=$(printf '%s\n' "$out" | awk '/^## Relevant history/{on=1} /^# /{on=0} on')
  assert_not_contains "$section" ".md" "no log note paths"
  assert_not_contains "$section" "$home" "no home paths"
  [ "$(printf '%s\n' "$section" | grep -c .)" -le 15 ] || fail "section exceeds 15 lines: $section"
  printf '%s\n' "$out" | awk '/^## Firstmate spec/{s=NR} /^## Relevant history/{h=NR} /^# Setup/{u=NR} END{exit !(s<h && h<u)}' \
    || fail "section must sit between Firstmate spec and Setup"
  pass "a brief for a task with history carries a bounded, path-free Relevant history"
}

test_empty_history_and_log_off_add_nothing() {
  local home out
  home=$(make_home empty)
  out=$(brief_for "$home" fresh-idea web)
  assert_not_contains "$out" "Relevant history" "no history"
  home=$(make_home off off)
  out=$(brief_for "$home" eng-12-followup billing)
  assert_not_contains "$out" "Relevant history" "log off"
  assert_contains "$out" "# Setup" "the scaffold is otherwise whole"
  pass "empty history or an off log leaves the brief unchanged"
}

test_own_open_row_alone_adds_nothing() {
  local home out
  home=$(make_home own-open)
  jq '.queue += [{"id":"lone-task","title":"Lone task","repo":"web","state":"queued","blocked_by":["eng-12-retry"]}]' \
    "$home/snapshot.json" > "$home/snapshot.tmp" && mv "$home/snapshot.tmp" "$home/snapshot.json"
  in_home "$home" "$ROOT/bin/fm-log.sh" sync >/dev/null 2>&1 || fail "sync failed"
  out=$(in_home "$home" "$ROOT/bin/fm-log.sh" recall --task lone-task --json 2>&1)
  assert_contains "$out" "\"task\": \"lone-task\"" "the index lists the task as open"
  out=$(brief_for "$home" lone-task web)
  assert_not_contains "$out" "Relevant history" "only the task's own open row"
  pass "a task whose only recall row is its own open item gets no Relevant history"
}

test_add_ignores_similarity_only_names() {
  local home out
  home=$(make_home similar)
  out=$(in_home "$home" "$ROOT/bin/fm-log.sh" recall Reyez --json 2>&1)
  assert_contains "$out" '"name": "Dana Reyes"' "recall resolves the near-miss by similarity"
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add near-miss "Pair with Reyez" 2>&1) || fail "add failed: $out"
  assert_not_contains "$out" "RELATED:" "a near-miss spelling"
  pass "add stays silent when a title only resembles an entity name"
}

test_add_prints_related_only_when_entities_resolve() {
  local home out
  home=$(make_home related)
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add plain-one "Tidy the readme" 2>&1) || fail "add failed: $out"
  assert_not_contains "$out" "RELATED:" "no entities"
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add dana-two "Pair with Dana Reyes" 2>&1) || fail "add failed: $out"
  assert_contains "$out" "RELATED:" "a title naming a person"
  assert_contains "$out" "retry with jitter" "a title naming a person"
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add tick-three "Something" --ticket ENG-12 2>&1) || fail "add failed: $out"
  assert_contains "$out" "RELATED:" "a ticket field"
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add tick-four "Something" --ticket ENG-12 --json 2>&1) || fail "add failed: $out"
  assert_not_contains "$out" "RELATED:" "--json output stays JSON"
  home=$(make_home related-off off)
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add tick-five "Something" --ticket ENG-12 2>&1) || fail "add failed: $out"
  assert_not_contains "$out" "RELATED:" "log off"
  pass "add prints RELATED only when its entities resolve and the log is on"
}

test_brief_history_is_keyed_never_project_only() {
  local home out section
  home=$(make_home keyed)
  printf '%s\n' \
    '{"v":1,"ts":'"$((T0 + 300))"',"event":"task.dispatched","task":"eng-99-limits","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":["ENG-99"]}' \
    '{"v":1,"ts":'"$((T0 + 360))"',"event":"task.status","task":"eng-99-limits","state":"done","key":null,"text":"rate limits raised"}' \
    >> "$home/state/fleet-ledger.jsonl"
  in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add tidy-billing "Tidy billing docs" --repo billing >/dev/null 2>&1 || fail "add failed"
  out=$(brief_for "$home" tidy-billing billing)
  assert_not_contains "$out" "Relevant history" "a project alone shares no key"
  in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add eng-99-more "Raise more limits" --repo billing --ticket ENG-99 >/dev/null 2>&1 \
    || fail "add failed"
  out=$(brief_for "$home" eng-99-more billing)
  section=$(printf '%s\n' "$out" | awk '/^## Relevant history/{on=1} /^# /{on=0} on')
  assert_contains "$section" "rate limits raised" "the shared ticket's items come back"
  assert_not_contains "$section" "jitter" "another ticket's decision stays out"
  pass "brief history carries only items keyed to the task, never the project alone"
}

test_brief_history_sees_the_task_own_new_rows() {
  local home out
  home=$(make_home fresh)
  printf '%s\n' '{"v":1,"ts":'"$((T0 + 300))"',"event":"captain.held","task":"late-task","reason":"ship now or wait for Q4?","until":null}' \
    >> "$home/state/fleet-ledger.jsonl"
  out=$(brief_for "$home" late-task billing)
  assert_contains "$out" "ship now or wait for Q4?" "an unsynced record for the briefed task reaches its history"
  pass "the brief updates the index before recalling the task's own history"
}

test_add_ignores_a_project_only_title() {
  local home out
  home=$(make_home project-title)
  out=$(in_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add billing-tidy "Tidy billing docs" 2>&1) || fail "add failed: $out"
  assert_not_contains "$out" "RELATED:" "a title naming only a project"
  pass "add prints no RELATED for a project named alone"
}

test_brief_carries_path_free_history
test_brief_history_is_keyed_never_project_only
test_brief_history_sees_the_task_own_new_rows
test_add_ignores_a_project_only_title
test_empty_history_and_log_off_add_nothing
test_own_open_row_alone_adds_nothing
test_add_ignores_similarity_only_names
test_add_prints_related_only_when_entities_resolve
