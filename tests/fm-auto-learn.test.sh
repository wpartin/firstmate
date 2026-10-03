#!/usr/bin/env bash
# tests/fm-auto-learn.test.sh - automatic learnings (bin/fm-auto-learn.sh) filed
# by the owners that see a corrected belief: a worker `learned:` line and a
# resolved blocker (bin/fm-classify-lib.sh), a captain answer overriding the
# recommendation (bin/fm-captain-hold.sh), pipeline fix commits (--nm-fixes, run
# by bin/fm-teardown.sh), and a CI check fixed on one PR (--ci-fixes, run by
# bin/fm-pr-check.sh); plus dedupe and nothing filed while the log is off.
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
  pass "a learned status line files an auto learning with its sources"
}

test_resolved_blocker_files_and_replay_dedupes() {
  local home
  home=$(make_home blocker)
  use_home "$home"
  printf 'blocked [key=db] [at=1]: tests fail on CI only\n' > "$home/state/t1.status"
  fold "$home"
  assert_equals "0" "$(count "$home")" "an open blocker files nothing"
  printf 'resolved [key=db] [at=2]: CI runs bash 3.2 without mapfile\n' >> "$home/state/t1.status"
  fold "$home"
  assert_equals "1" "$(count "$home")" "resolving the blocker files one learning"
  assert_contains "$(learnings "$home")" "Blocked: tests fail on CI only" "the blocker"
  assert_contains "$(learnings "$home")" "Corrected by: CI runs bash 3.2 without mapfile" "the cause"
  rm -f "$home"/state/.t1.open-decisions-cursor
  fold "$home"
  assert_equals "1" "$(count "$home")" "a full re-fold files nothing twice"
  pass "a resolved blocker files its cause once"
}

test_captain_override_files_only_on_a_different_pick() {
  local home
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home override)
  use_home "$home"
  "$ROOT/bin/fm-captain-hold.sh" hold pick-a --title "Pick a" --reason "x or y; recommend: postgres" >/dev/null
  printf 'Go with postgres.\n' > "$home/a.txt"
  "$ROOT/bin/fm-captain-hold.sh" answer pick-a --decision-file "$home/a.txt" >/dev/null
  assert_equals "0" "$(count "$home")" "an answer agreeing with the recommendation files nothing"
  "$ROOT/bin/fm-captain-hold.sh" hold pick-b --title "Pick b" --reason "x or y; recommend: postgres" >/dev/null
  printf 'Use sqlite.\n' > "$home/b.txt"
  "$ROOT/bin/fm-captain-hold.sh" answer pick-b --decision-file "$home/b.txt" >/dev/null
  assert_equals "1" "$(count "$home")" "an overriding answer files one learning"
  assert_contains "$(learnings "$home")" "Firstmate recommended postgres" "names the recommendation"
  assert_contains "$(learnings "$home")" "Corrected by: Use sqlite." "carries the answer"
  pass "a captain answer overriding the recommendation files a learning"
}

test_nm_fix_commits_file_once() {
  local home repo
  home=$(make_home nm)
  use_home "$home"
  repo="$home/repo"
  git init -q -b main "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$repo" checkout -q -b fm/x
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat: thing"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "no-mistakes(review): Quote the path"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "no-mistakes(document): Document it"
  "$AUTO" --nm-fixes "$home/state" t1 "$repo" main
  "$AUTO" --nm-fixes "$home/state" t1 "$repo" main
  assert_equals "1" "$(count "$home")" "one learning per review/test/lint fix, filed once"
  assert_contains "$(learnings "$home")" "no-mistakes review found the first draft wrong: Quote the path" "fact"
  pass "pipeline fix commits file one deduplicated learning each"
}

test_ci_fix_files_the_fixing_commit() {
  local home fb
  home=$(make_home ci)
  use_home "$home"
  fb="$home/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  */pulls/7/commits*) printf 'aaa\tfirst try\nbbb\tpin node 20\n' ;;
  */commits/aaa/check-runs*) printf 'failure\ttest\nsuccess\tlint\n' ;;
  */commits/bbb/check-runs*) printf 'success\ttest\nsuccess\tlint\n' ;;
esac
SH
  chmod +x "$fb/gh"
  PATH="$fb:$PATH" "$AUTO" --ci-fixes "$home/state" t1 acme/web 7
  assert_equals "1" "$(count "$home")" "only the check that failed then passed files"
  assert_contains "$(learnings "$home")" "CI check test failed on acme/web PR 7" "fact"
  assert_contains "$(learnings "$home")" "fixed by: pin node 20" "fixing commit"
  pass "a CI check fixed on the same PR files its fixing commit"
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
test_resolved_blocker_files_and_replay_dedupes
test_captain_override_files_only_on_a_different_pick
test_nm_fix_commits_file_once
test_ci_fix_files_the_fixing_commit
test_log_off_files_nothing
