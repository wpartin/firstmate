#!/usr/bin/env bash
# Behavior tests for bin/fm-comment-length-check.sh.
#
# Everything here drives the executable: every fixture is a real git repository
# with real commits, and every assertion reads the script's stdout, its stderr,
# and its exit code. Nothing inspects the script's source.
#
# The cases that matter most are the ones where a naive scanner is wrong: a
# comment that was already in a touched file, a `#` that is literal text inside
# a YAML block scalar, and a `/*` that lives inside a string.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-comment-length-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-comment-length-check)

git_commit() {
  local dir=$1 msg=$2
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$msg"
}

# The main branch already carries a multi-line comment, so every case can prove a pre-existing run stays out of scope.
make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -q -b main 2>/dev/null || true
  cat > "$dir/existing.ts" <<'TS'
// a comment that was already here
// and its second line
export const existing = 1;
TS
  git_commit "$dir" base
  git -C "$dir" checkout -q -b feature
}

# run_check <dir> [args...]: capture stdout, stderr and exit code separately so a case can assert a clean run prints nothing.
run_check() {
  local dir=$1
  shift
  OUT=$("$CHECK" --project "$dir" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

# --- a clean branch prints nothing ------------------------------------------

test_clean_branch_is_silent() {
  local dir="$TMP_ROOT/clean"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
// one line is fine
export const a = 1;
// so is another one on its own
export const b = 2;
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "a branch whose added comments are all one line must pass"
  [ -z "$OUT" ] || fail "a clean run must print nothing to stdout, got: $OUT"
  pass "fm-comment-length-check: a clean branch exits 0 and prints nothing"
}

# --- a two-line inline run is reported --------------------------------------

test_two_line_inline_run_is_reported() {
  local dir="$TMP_ROOT/inline"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
export const a = 1;
// the first line of a run
// the second line of the same run
export const b = 2;
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a two-line inline comment run must fail"
  assert_contains "$OUT" "added.ts:2-3" "the run must be named with its file and line range"
  assert_contains "$OUT" "2-line comment run" "the run's length must be stated"
  assert_contains "$OUT" "FAILED" "a failing run must say so"
  pass "fm-comment-length-check: a two-line inline run is reported with file and line"
}

# --- a multi-line JSDoc block is reported -----------------------------------

test_jsdoc_block_is_reported() {
  local dir="$TMP_ROOT/jsdoc"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
/**
 * Does a thing.
 *
 * @param x the thing
 */
export function f(x: number) { return x; }
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a multi-line JSDoc block must fail"
  assert_contains "$OUT" "added.ts:1-5" "the JSDoc block must be reported as one run over its whole span"
  assert_contains "$OUT" "5-line comment run" "a blank line inside a block comment must not split the run"
  pass "fm-comment-length-check: a multi-line JSDoc block is one reported run"
}

# --- a pre-existing run in a touched file is NOT reported -------------------

test_preexisting_run_in_touched_file_is_not_reported() {
  local dir="$TMP_ROOT/preexisting"
  make_repo "$dir"
  printf 'export const appended = 2;\n' >> "$dir/existing.ts"
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "touching a file must not put its existing comments in scope"
  [ -z "$OUT" ] || fail "a pre-existing comment run must not be reported, got: $OUT"
  pass "fm-comment-length-check: a pre-existing run in a touched file is left alone"
}

# --- a file type outside the language scope --------------------------------

test_unhandled_file_type_is_named_not_measured() {
  local dir="$TMP_ROOT/unhandled"
  make_repo "$dir"
  cat > "$dir/main.tf" <<'HCL'
# a terraform comment
# and its second line
resource "null_resource" "x" {}
HCL
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "a file type outside the language scope must not fail the branch"
  [ -z "$OUT" ] || fail "an unmeasured file must print nothing to stdout, got: $OUT"
  assert_contains "$ERR" ".tf" "the unmeasured extension must be named on stderr rather than skipped silently"
  pass "fm-comment-length-check: an unhandled file type is named on stderr, not measured"
}

# --- trailing comments never form a run ------------------------------------

test_trailing_comments_are_not_a_run() {
  local dir="$TMP_ROOT/trailing"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
export const a = 1; // why a is one
export const b = 2; // why b is two
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "two lines that each end in a comment are two one-line comments"
  [ -z "$OUT" ] || fail "trailing comments must not be reported as a run, got: $OUT"
  pass "fm-comment-length-check: consecutive trailing comments are not a multi-line run"
}

# --- a blank line separates two one-line comments ---------------------------

test_blank_line_separates_comments() {
  local dir="$TMP_ROOT/blank"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
// first comment

// second comment
export const a = 1;
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "a blank line between two comments makes them two comments"
  [ -z "$OUT" ] || fail "a blank line must end a run, got: $OUT"
  pass "fm-comment-length-check: a blank line ends a run"
}

# --- comment syntax inside a string is not a comment ------------------------

test_comment_syntax_inside_a_string_is_not_a_comment() {
  local dir="$TMP_ROOT/strings"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
export const a = "this /* is not */ a comment";
export const b = 'neither // is this';
export const c = /https:\/\/example\.invalid/;
export const d = `a template
spanning two lines`;
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "comment delimiters inside strings, regexes and templates are not comments"
  [ -z "$OUT" ] || fail "string content must not be lexed as a comment, got: $OUT"
  pass "fm-comment-length-check: comment syntax inside strings, regexes and templates is ignored"
}

# --- an apostrophe in JSX prose must not become a parse failure -------------

test_apostrophe_in_jsx_prose_recovers() {
  local dir="$TMP_ROOT/jsx"
  make_repo "$dir"
  cat > "$dir/added.tsx" <<'TSX'
export const El = () => <p>don't panic</p>;
export const Other = () => <p>it's fine</p>;
TSX
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "an apostrophe in JSX prose must not be reported as an unterminated string"
  [ -z "$OUT" ] || fail "JSX prose must not produce a run, got: $OUT"
  pass "fm-comment-length-check: an apostrophe in JSX prose recovers instead of failing"
}

# --- YAML comment runs are measured ----------------------------------------

test_yaml_comment_run_is_reported() {
  local dir="$TMP_ROOT/yaml"
  make_repo "$dir"
  cat > "$dir/conf.yaml" <<'YAML'
# the first line of a yaml run
# the second line of the same run
key: value
YAML
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "consecutive YAML comment lines are a run"
  assert_contains "$OUT" "conf.yaml:1-2" "the YAML run must be named with its file and line range"
  pass "fm-comment-length-check: consecutive YAML comment lines are reported"
}

# --- YAML block scalar content is literal text, not comments ----------------

test_yaml_block_scalar_content_is_not_comments() {
  local dir="$TMP_ROOT/yaml-block"
  make_repo "$dir"
  cat > "$dir/conf.yaml" <<'YAML'
script: |
  # this is literal shell, not a yaml comment
  # and so is this second line
  echo hello
other: value
plain: it's an apostrophe, not a quoted scalar
YAML
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "a block scalar's body is literal text even when its lines begin with #"
  [ -z "$OUT" ] || fail "block scalar content must not be lexed as comments, got: $OUT"
  pass "fm-comment-length-check: YAML block scalar content is not read as comments"
}

# --- source the lexer cannot finish fails loudly ----------------------------

test_unterminated_block_comment_fails_loudly() {
  local dir="$TMP_ROOT/unterminated"
  make_repo "$dir"
  cat > "$dir/added.ts" <<'TS'
export const a = 1;
/* this block comment is never closed
still inside it
TS
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 2 "$RC" "source the lexer cannot finish must not be reported as clean"
  assert_contains "$ERR" "unterminated block comment" "the refusal must name what could not be lexed"
  assert_contains "$ERR" "added.ts" "the refusal must name the file"
  pass "fm-comment-length-check: an unlexable file exits 2 instead of reporting a pass"
}

# --- every breach is named in one run ---------------------------------------

test_all_runs_are_reported_together() {
  local dir="$TMP_ROOT/many"
  make_repo "$dir"
  cat > "$dir/one.ts" <<'TS'
// run one first line
// run one second line
export const a = 1;
TS
  cat > "$dir/two.yaml" <<'YAML'
# run two first line
# run two second line
key: value
YAML
  git_commit "$dir" work

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "several runs must still fail"
  assert_contains "$OUT" "one.ts:1-2" "the TypeScript run must be named"
  assert_contains "$OUT" "two.yaml:1-2" "the YAML run must be named"
  assert_contains "$OUT" "2 multi-line comment run(s)" "the total must be stated"
  pass "fm-comment-length-check: every run is named in a single pass"
}

# --- refusals -------------------------------------------------------------

test_unresolvable_ref_is_refused() {
  local dir="$TMP_ROOT/badref"
  make_repo "$dir"
  printf 'export const c = 3;\n' > "$dir/added.ts"
  git_commit "$dir" work

  run_check "$dir" --base does-not-exist --head feature
  expect_code 2 "$RC" "an unresolvable base ref must not be reported as a clean branch"
  assert_contains "$ERR" "base ref does not resolve" "the refusal must name the unresolvable ref"
  pass "fm-comment-length-check: an unresolvable ref exits 2"
}

test_usage_errors_are_refused() {
  OUT=$("$CHECK" --project "$TMP_ROOT" 2>&1); RC=$?
  expect_code 2 "$RC" "a missing --base must be refused"
  assert_contains "$OUT" "--base" "the refusal must name the missing argument"

  OUT=$("$CHECK" --nonsense 2>&1); RC=$?
  expect_code 2 "$RC" "an unknown argument must be refused"
  assert_contains "$OUT" "unknown argument" "the refusal must name the unknown argument"

  OUT=$("$CHECK" --project /does/not/exist --base main 2>&1); RC=$?
  expect_code 2 "$RC" "a missing project directory must be refused"
  pass "fm-comment-length-check: usage errors exit 2 with a named reason"
}

# --- the language scope has one owner ---------------------------------------

test_print_scope_is_machine_readable() {
  OUT=$("$CHECK" --print-scope 2>&1); RC=$?
  expect_code 0 "$RC" "--print-scope must succeed without a project or a ref"
  assert_contains "$OUT" "language=javascript-typescript" "the scope must name the JavaScript and TypeScript family"
  assert_contains "$OUT" "language=yaml" "the scope must name YAML"
  assert_contains "$OUT" ".tsx" "the scope must list the extensions it measures"
  assert_not_contains "$OUT" ".tf" "an unmeasured language must not appear in the scope"
  pass "fm-comment-length-check: --print-scope is the machine-readable owner of the language scope"
}

test_help_states_the_contract() {
  OUT=$("$CHECK" --help 2>&1); RC=$?
  expect_code 0 "$RC" "--help must succeed"
  assert_contains "$OUT" "one line" "the help must state the rule"
  assert_contains "$OUT" "NOT MEASURED" "the help must state the language boundary"
  pass "fm-comment-length-check: --help states the rule and the language boundary"
}

test_clean_branch_is_silent
test_two_line_inline_run_is_reported
test_jsdoc_block_is_reported
test_preexisting_run_in_touched_file_is_not_reported
test_unhandled_file_type_is_named_not_measured
test_trailing_comments_are_not_a_run
test_blank_line_separates_comments
test_comment_syntax_inside_a_string_is_not_a_comment
test_apostrophe_in_jsx_prose_recovers
test_yaml_comment_run_is_reported
test_yaml_block_scalar_content_is_not_comments
test_unterminated_block_comment_fails_loudly
test_all_runs_are_reported_together
test_unresolvable_ref_is_refused
test_usage_errors_are_refused
test_print_scope_is_machine_readable
test_help_states_the_contract
