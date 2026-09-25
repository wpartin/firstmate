#!/usr/bin/env bash
# Behavior tests for bin/fm-commit-trailer-check.sh and bin/fm-commit-msg-hook.sh.
#
# Every fixture is a real git repository with real commit messages, and every
# assertion reads stdout, stderr, the exit code, or the message git actually
# stored. Nothing inspects either script's source.
#
# The prevention case is driven the whole way through git: the hook is installed
# the way the documented install does it, as a symlink, and the assertion is on
# the committed message rather than on anything the hook printed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-commit-trailer-check.sh"
HOOK="$ROOT/bin/fm-commit-msg-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-commit-trailer-check)

git_commit_msg() {
  local dir=$1
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -F -
}

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -q -b main 2>/dev/null || true
  printf 'base\n' > "$dir/f.txt"
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git -C "$dir" checkout -q -b feature
}

run_check() {
  OUT=$("$CHECK" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

# --- a clean range passes ---------------------------------------------------

test_clean_range_passes() {
  local dir="$TMP_ROOT/clean"
  make_repo "$dir"
  printf 'one\n' >> "$dir/f.txt"
  git_commit_msg "$dir" <<'MSG'
feat: an honest commit

Co-authored-by: A Human <human@example.invalid>
MSG

  run_check --project "$dir" --base main --head feature
  expect_code 0 "$RC" "a branch with no AI attribution must pass"
  [ -z "$OUT" ] || fail "a clean range must print nothing, got: $OUT"
  pass "fm-commit-trailer-check: a clean range passes and leaves a human co-author alone"
}

# --- the two trailers are reported separately -------------------------------

test_both_trailer_classes_are_reported_separately() {
  local dir="$TMP_ROOT/dirty"
  make_repo "$dir"
  printf 'one\n' >> "$dir/f.txt"
  git_commit_msg "$dir" <<'MSG'
feat: a commit the harness decorated

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_example0000000000
MSG

  run_check --project "$dir" --base main --head feature
  expect_code 1 "$RC" "AI attribution trailers must fail the branch"
  assert_contains "$OUT" "(coauthor)" "the co-author trailer must be classed as a co-author"
  assert_contains "$OUT" "(session)" "the session link must be classed separately from the co-author"
  assert_contains "$OUT" "1 AI co-author trailer(s) and 1 session-link trailer(s)" "each class must be counted on its own"
  assert_contains "$OUT" "rewriting shared history" "the report must say why a landed trailer cannot simply be removed later"
  pass "fm-commit-trailer-check: the co-author and session trailers are reported as separate classes"
}

# --- a human co-author is never a finding -----------------------------------

test_human_coauthor_is_not_reported() {
  local dir="$TMP_ROOT/human"
  make_repo "$dir"
  printf 'one\n' >> "$dir/f.txt"
  git_commit_msg "$dir" <<'MSG'
feat: paired with a person

Co-authored-by: Dana Example <dana@example.invalid>
Co-authored-by: Sam Cursory <sam@people.invalid>
MSG

  run_check --project "$dir" --base main --head feature
  expect_code 0 "$RC" "a human co-author must never be reported"
  [ -z "$OUT" ] || fail "human co-authors must not be reported, got: $OUT"
  pass "fm-commit-trailer-check: human co-authors are left alone"
}

# --- only this branch's own commits are examined ----------------------------

test_base_branch_commits_are_not_examined() {
  local dir="$TMP_ROOT/scoped"
  make_repo "$dir"
  git -C "$dir" checkout -q main
  printf 'main work\n' >> "$dir/f.txt"
  git_commit_msg "$dir" <<'MSG'
chore: something already on main

Co-Authored-By: Claude <noreply@anthropic.com>
MSG
  git -C "$dir" checkout -q feature
  printf 'branch work\n' >> "$dir/g.txt"
  git_commit_msg "$dir" <<'MSG'
feat: clean branch work
MSG

  run_check --project "$dir" --base main --head feature
  expect_code 0 "$RC" "a trailer already on the base branch is not this branch's finding"
  pass "fm-commit-trailer-check: only the commits this branch adds are examined"
}

# --- one message file, the hook calling convention --------------------------

test_message_mode_detects_without_changing_the_file() {
  local msg="$TMP_ROOT/msg-detect.txt"
  cat > "$msg" <<'MSG'
feat: something

Body that must survive.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_abc
MSG
  local before
  before=$(cat "$msg")

  run_check --message "$msg"
  expect_code 1 "$RC" "a message carrying the trailers must fail"
  assert_contains "$OUT" "coauthor" "the co-author trailer must be named"
  assert_contains "$OUT" "session" "the session trailer must be named"
  [ "$(cat "$msg")" = "$before" ] || fail "detection without --strip must not change the message file"
  pass "fm-commit-trailer-check: --message detects without modifying the file"
}

test_strip_removes_only_the_trailers() {
  local msg="$TMP_ROOT/msg-strip.txt"
  cat > "$msg" <<'MSG'
feat: something

Body that must survive.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Co-authored-by: Dana Example <dana@example.invalid>
Claude-Session: https://claude.ai/code/session_abc
MSG

  run_check --message "$msg" --strip
  expect_code 0 "$RC" "--strip must succeed after removing the trailers"
  assert_contains "$ERR" "removed AI attribution trailers" "--strip must report what it removed"

  local after
  after=$(cat "$msg")
  assert_contains "$after" "feat: something" "the subject must survive"
  assert_contains "$after" "Body that must survive." "the body must survive"
  assert_contains "$after" "Dana Example" "a human co-author must survive"
  assert_not_contains "$after" "anthropic.com" "the AI co-author must be gone"
  assert_not_contains "$after" "Claude-Session" "the session trailer must be gone"

  run_check --message "$msg"
  expect_code 0 "$RC" "the stripped message must now be clean"
  pass "fm-commit-trailer-check: --strip removes only the offending trailers"
}

test_git_comment_lines_are_ignored() {
  local msg="$TMP_ROOT/msg-comments.txt"
  cat > "$msg" <<'MSG'
feat: something

# Please enter the commit message for your changes.
# Co-Authored-By: Claude <noreply@anthropic.com>
MSG

  run_check --message "$msg"
  expect_code 0 "$RC" "a trailer inside git's own instruction comments is not being committed"
  pass "fm-commit-trailer-check: git's commented instruction lines are ignored"
}

# --- refusals ---------------------------------------------------------------

test_strip_is_refused_on_a_range() {
  local dir="$TMP_ROOT/strip-range"
  make_repo "$dir"
  run_check --project "$dir" --base main --strip
  expect_code 2 "$RC" "--strip on an existing range must be refused"
  assert_contains "$ERR" "rewrite history" "the refusal must say why stripping committed history is not done here"
  pass "fm-commit-trailer-check: --strip is refused on a committed range"
}

test_usage_errors_are_refused() {
  run_check --help
  expect_code 0 "$RC" "--help must succeed"

  OUT=$("$CHECK" 2>&1); RC=$?
  expect_code 2 "$RC" "no mode at all must be refused"
  assert_contains "$OUT" "nothing to examine" "the refusal must name what is missing"

  OUT=$("$CHECK" --message /does/not/exist 2>&1); RC=$?
  expect_code 2 "$RC" "a missing message file must be refused"

  OUT=$("$CHECK" --project . --base main --message m 2>&1); RC=$?
  expect_code 2 "$RC" "the two modes must be mutually exclusive"
  pass "fm-commit-trailer-check: usage errors exit 2 with a named reason"
}

# --- prevention, driven through git -----------------------------------------

test_commit_msg_hook_strips_before_the_commit_exists() {
  local dir="$TMP_ROOT/hooked"
  make_repo "$dir"
  ln -sf "$HOOK" "$dir/.git/hooks/commit-msg"

  printf 'one\n' >> "$dir/f.txt"
  git_commit_msg "$dir" <<'MSG'
feat: a commit made with the hook installed

Body that must survive.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_xyz
MSG

  local stored
  stored=$(git -C "$dir" log -1 --format=%B)
  assert_contains "$stored" "a commit made with the hook installed" "the commit must still be created"
  assert_contains "$stored" "Body that must survive." "the hook must not damage the message body"
  assert_not_contains "$stored" "anthropic.com" "the co-author trailer must never reach the commit"
  assert_not_contains "$stored" "Claude-Session" "the session trailer must never reach the commit"

  run_check --project "$dir" --base main --head feature
  expect_code 0 "$RC" "a branch built with the hook installed must audit clean"
  pass "fm-commit-msg-hook: an installed hook keeps both trailers out of the commit"
}

test_hook_refuses_without_a_message_file() {
  OUT=$("$HOOK" 2>&1); RC=$?
  expect_code 2 "$RC" "the hook must refuse when git passed it no message file"
  pass "fm-commit-msg-hook: it refuses rather than silently passing when called wrong"
}

test_clean_range_passes
test_both_trailer_classes_are_reported_separately
test_human_coauthor_is_not_reported
test_base_branch_commits_are_not_examined
test_message_mode_detects_without_changing_the_file
test_strip_removes_only_the_trailers
test_git_comment_lines_are_ignored
test_strip_is_refused_on_a_range
test_usage_errors_are_refused
test_commit_msg_hook_strips_before_the_commit_exists
test_hook_refuses_without_a_message_file
