#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.77\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering

# The board parity surfaces render from a `build --static` page, which needs no
# Lavish session, so they are exercised without a listener.
render_static() {  # <home> <payload-json> [scenario-json] [live 0|1]
  local home=$1 payload=$2 scenario=${3:-[]} live=${4:-1}
  printf '%s\n' "$payload" > "$home/payload.json"
  printf '%s\n' "$scenario" > "$home/scenario.json"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$BOARD" build --static --out "$home/static.html" "$home/payload.json" >/dev/null \
    || fail "the static board did not build"
  BOARD_HARNESS_LIVE=$live node "$HARNESS" "$home/static.html" "$home/scenario.json" \
    || fail "the static board could not be rendered"
}

PARITY_PAYLOAD='{"schema":"fm-bearings-board.v1","home":"h","generated":"2026-09-24T09:00Z","prs_live":false,
 "captains_call":[{"key":"pick-colour","type":"decision","repo":"web","title":"Pick a colour","options":[],"allow_freeform":true}],
 "underway":[{"id":"fix-login","kind":"ship","state":"working","repo":"web","name":"Fix login","doing":"writing tests",
   "unlanded":{"branch":"fm/fix-login","head":"0123456789abcdef0123456789abcdef01234567","commits":2,"pr_url":"https://github.com/acme/web/pull/7"}}],
 "landed":[],
 "charted":[{"id":"q2","repo":"web","title":"Queued thing","reason":"","dispatchable":true},
            {"id":"b1","repo":"web","title":"Blocked one","reason":"blocked by q2","dispatchable":false}]}'

test_count_cards_filter_the_board() {
  local home out
  home=$(make_home filter-cards)
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"stat","label":"underway"}]')
  printf '%s' "$out" | jq -e '.error == "" and .filtered == true and .shown == ["underway"]
    and ([.stats[] | select(.active) | .label] == ["underway"])
    and ([.stats[] | select(.disabled) | .label] == ["landed recently"])' >/dev/null \
    || fail "a count card did not filter the board to its section: $out"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"stat","label":"underway"},{"click":"stat","label":"underway"}]')
  printf '%s' "$out" | jq -e '.filtered == false and .shown == []' >/dev/null \
    || fail "selecting the active count card again did not show everything: $out"
  pass "count cards filter the board to their section and toggle back"
}

test_row_options_queue_action_instructions() {
  local home out
  home=$(make_home row-options)
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"charted","row":0},{"pick":"dispatch"},{"submit":"modal"}]')
  printf '%s' "$out" | jq -e '
    ([.charted[] | .options] == [true, true]) and ([.underway[] | .options] == [true])
    and (.prompts | length) == 1
    and .prompts[0].data == {schema:"fm-bearings-answer.v1",question:"action.q2",selection:"dispatch",note:""}' >/dev/null \
    || fail "a charted row did not queue its dispatch instruction: $out"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"charted","row":1}]')
  printf '%s' "$out" | jq -e '.modal.open == true and .modal.actions == ["forward","unblock","park","drop"]' >/dev/null \
    || fail "a blocked row did not offer unblock without dispatch: $out"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"underway","row":0},{"pick":"note"},{"submit":"modal"}]')
  printf '%s' "$out" | jq -e '(.prompts | length) == 0 and .modal.open == true' >/dev/null \
    || fail "an empty steer note was queued: $out"
  pass "row options offer each row its actions and queue action.<task> instructions"
}

test_drop_states_exactly_what_it_discards() {
  local home out
  home=$(make_home drop-confirm)
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"underway","row":0},{"pick":"drop"},{"submit":"modal"}]')
  printf '%s' "$out" | jq -e '
    (.modal.confirm | contains("branch fm/fix-login at 0123456789ab (2 unlanded commits)"))
    and (.modal.confirm | contains("open PR https://github.com/acme/web/pull/7"))
    and (.prompts | length) == 0' >/dev/null \
    || fail "a drop with unlanded work did not state the discard and wait for its confirmation: $out"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"underway","row":0},{"pick":"drop"},{"tick":"discard"},{"note":"superseded"},{"submit":"modal"}]')
  printf '%s' "$out" | jq -e '.prompts[0].data == {schema:"fm-bearings-answer.v1",question:"action.fix-login",selection:"drop",
      note:"discard=fm/fix-login@0123456789abcdef0123456789abcdef01234567 pr=https://github.com/acme/web/pull/7 | superseded"}' >/dev/null \
    || fail "a confirmed drop did not name exactly the discarded branch, head, and PR: $out"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[{"click":"options","section":"charted","row":0},{"pick":"drop"},{"submit":"modal"}]')
  printf '%s' "$out" | jq -e '.modal.confirm == "" and .prompts[0].data.selection == "drop" and .prompts[0].data.note == ""' >/dev/null \
    || fail "a drop with nothing unlanded asked for a discard confirmation: $out"
  pass "drop states exactly what it discards, and sends only after that is confirmed"
}

test_static_copy_is_read_only() {
  local home out
  home=$(make_home static-copy)
  printf 'https://lavish.example/session/abc\n' > "$home/state/.log-board-url"
  out=$(render_static "$home" "$PARITY_PAYLOAD" '[]' 0)
  printf '%s' "$out" | jq -e '.error == "" and (.staticBanner | contains("read-only copy"))
    and (.staticBanner | contains("Open the live board")) and .enabledControls == 0
    and .disabledControls > 0' >/dev/null \
    || fail "the static copy left a control enabled or did not point at the live board: $out"
  pass "a static copy disables every control and points at the live board"
}

test_count_cards_filter_the_board
test_row_options_queue_action_instructions
test_drop_states_exactly_what_it_discards
test_static_copy_is_read_only
