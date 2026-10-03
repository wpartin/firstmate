#!/usr/bin/env bash
# tests/fm-auto-learn.test.sh - automatic learnings (bin/fm-auto-learn.sh) filed
# for a worker `learned:` line (bin/fm-classify-lib.sh), plus dedupe, no learning
# from a resolved blocker, and nothing filed while the log is off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-learn)
AUTO="$ROOT/bin/fm-auto-learn.sh"
export TZ=UTC FM_LOG_TODAY=2026-09-28

make_home() {  # <name> [off]: prints the home, with the log on unless "off"
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "${2:-on}" > "$home/config/log"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '\n' > "$home/data/backlog.md"
  printf 'kind=ship\nproject=/src/projects/web\n' > "$home/state/t1.meta"
  printf '%s\n' "$home"
}

use_home() {  # <home>
  export FM_HOME=$1 FM_STATE_OVERRIDE=$1/state FM_DATA_OVERRIDE=$1/data FM_CONFIG_OVERRIDE=$1/config
}

learnings() { cat "$1"/data/log/learnings/auto-*.md 2>/dev/null; }
count() { find "$1/data/log/learnings" -name 'auto-*.md' 2>/dev/null | wc -l | tr -d ' '; }

fold() {  # <home>: run the incremental open-decisions fold over t1's status log
  ( . "$ROOT/bin/fm-classify-lib.sh"; status_open_decisions_incremental "$1/state/t1.status" >/dev/null )
}

test_learned_line_files_with_sources() {
  local home
  home=$(make_home learned)
  use_home "$home"
  printf 'working [at=1]: started\nlearned [at=2]: the API paginates at 50, not 100\n' > "$home/state/t1.status"
  fold "$home"
  assert_equals "1" "$(count "$home")" "one learning from the learned line"
  assert_contains "$(learnings "$home")" "# the API paginates at 50, not 100" "title is the fact"
  assert_contains "$(learnings "$home")" 'tasks: ["t1"]' "task source"
  assert_contains "$(learnings "$home")" 'projects: ["web"]' "project source"
  assert_contains "$(learnings "$home")" "origin: auto" "marked auto"
  rm -f "$home"/state/.t1.open-decisions-cursor
  fold "$home"
  assert_equals "1" "$(count "$home")" "a full re-fold files nothing twice"
  pass "a learned status line files one deduplicated learning with its sources"
}

test_resolved_blocker_files_nothing() {
  local home
  home=$(make_home blocker)
  use_home "$home"
  printf 'blocked [key=db] [at=1]: tests fail on CI only\n' > "$home/state/t1.status"
  fold "$home"
  assert_equals "0" "$(count "$home")" "an open blocker files nothing"
  printf 'resolved [key=db] [at=2]: CI runs bash 3.2 without mapfile\n' >> "$home/state/t1.status"
  fold "$home"
  assert_equals "0" "$(count "$home")" "a resolved blocker files nothing"
  pass "a resolved blocker files no learning"
}

test_log_off_files_nothing() {
  local home
  home=$(make_home off off)
  use_home "$home"
  printf 'learned [at=2]: something true\n' > "$home/state/t1.status"
  fold "$home"
  "$AUTO" "$home/state" t1 learned k "a fact"
  assert_absent "$home/data/log" "no log folder while the log is off"
  pass "nothing is filed while the log is off"
}

test_learned_line_files_with_sources
test_resolved_blocker_files_nothing
test_log_off_files_nothing
