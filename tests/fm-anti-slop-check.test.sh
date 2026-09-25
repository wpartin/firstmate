#!/usr/bin/env bash
# Behavior tests for bin/fm-anti-slop-check.sh.
#
# Everything here drives the executable: fixtures are real git repositories,
# real workflow files, and real description files, and every assertion reads the
# script's stdout and exit code. Nothing inspects the script's source.
#
# The rule limits under test are written into each fixture's own workflow, and
# deliberately differ from any real project's, so a passing run proves the
# script reads the project's configuration rather than a built-in number.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-anti-slop-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-anti-slop-check)

# A workflow with every rule under test enabled at a small, distinctive limit.
# The blocked terms are fixture words: no rule here depends on the vocabulary
# any particular project blocks.
write_workflow() {
  local dir=$1
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
name: Anti Slop
on:
  pull_request:
    types: [opened, edited]
jobs:
  anti-slop:
    runs-on: ubuntu-latest
    steps:
      - id: anti-slop
        uses: peakoss/anti-slop@57858eead489d08b255fab2af45a506c2ca6eab2 # v0.3.0
        with:
          max-failures: 1
          max-changed-files: 3
          max-changed-lines: 40
          max-emoji-count: 1
          max-code-references: 2
          max-description-length: 200
          max-commit-message-length: 60
          blocked-terms: |
            forbiddenword
            other-banned-phrase
          blocked-paths: LICENSE
YAML
}

# A repository whose branch is comfortably inside every size limit.
make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c init.defaultBranch=main checkout -q -b main 2>/dev/null || true
  write_workflow "$dir"
  printf 'one\n' > "$dir/file.txt"
  printf 'a license\n' > "$dir/LICENSE"
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git -C "$dir" checkout -q -b feature
}

commit_all() {
  local dir=$1 msg=$2
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$msg"
}

# run_check <dir> [extra args...]: capture combined output and exit code into
# the globals OUT and RC so each case can assert on both.
run_check() {
  local dir=$1
  shift
  OUT=$("$CHECK" --project "$dir" "$@" 2>&1)
  RC=$?
}

# --- a clean branch and a clean body pass -----------------------------------

test_clean_branch_and_body_pass() {
  local dir="$TMP_ROOT/clean"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'A short description that stays well inside every configured limit.\n' > "$TMP_ROOT/clean-body.md"

  run_check "$dir" --base main --head feature --body "$TMP_ROOT/clean-body.md" --title 'fix: a clean title'
  expect_code 0 "$RC" "a branch and body inside every limit must pass"
  assert_contains "$OUT" "PASSED" "a clean run must state that every measured rule passed"
  assert_not_contains "$OUT" "FAIL " "a clean run must name no breach"
  assert_not_contains "$OUT" "SKIP " "with both a base ref and a body, no rule may go unmeasured"
  pass "fm-anti-slop-check: a clean branch and body pass with every rule measured"
}

# Every measured line must carry its measured number AND its limit, so the
# reader can see how close the branch is rather than only whether it passed.
test_every_rule_reports_measurement_and_limit() {
  local dir="$TMP_ROOT/measured"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'Short body.\n' > "$TMP_ROOT/measured-body.md"

  run_check "$dir" --base main --head feature --body "$TMP_ROOT/measured-body.md" --title t
  expect_code 0 "$RC" "the measured fixture must pass"
  assert_contains "$OUT" "1 files, limit 3" "changed files must print the count and the configured limit"
  assert_contains "$OUT" "lines, limit 40" "changed lines must print the count and the configured limit"
  assert_contains "$OUT" "chars, limit 200" "description length must print the count and the configured limit"
  assert_contains "$OUT" "0 emoji, limit 1" "emoji must print the count and the configured limit"
  assert_contains "$OUT" "0 references, limit 2" "code references must print the count and the configured limit"
  assert_contains "$OUT" "0 of 2 blocked terms present" "blocked terms must print how many of the configured terms appear"
  assert_contains "$OUT" "0 changed files in 1 blocked paths" "blocked paths must print the count against the configured paths"
  pass "fm-anti-slop-check: every rule prints its measured number against its limit"
}

# --- each rule breaches on its own and is named -----------------------------

test_changed_lines_breach_is_named() {
  local dir="$TMP_ROOT/lines"
  make_repo "$dir"
  seq 1 60 > "$dir/file.txt"
  commit_all "$dir" work
  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a branch over the changed-line limit must exit non-zero"
  assert_contains "$OUT" "FAIL  max-changed-lines" "the changed-line breach must be named"
  assert_contains "$OUT" "limit 40" "the changed-line breach must show the configured limit"
  pass "fm-anti-slop-check: a changed-line breach is named"
}

test_changed_files_breach_is_named() {
  local dir="$TMP_ROOT/files"
  make_repo "$dir"
  local i
  for i in 1 2 3 4 5; do printf 'x\n' > "$dir/new$i.txt"; done
  commit_all "$dir" work
  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a branch over the changed-file limit must exit non-zero"
  assert_contains "$OUT" "FAIL  max-changed-files" "the changed-file breach must be named"
  assert_contains "$OUT" "5 files, limit 3" "the changed-file breach must show the count and the limit"
  pass "fm-anti-slop-check: a changed-file breach is named"
}

test_description_length_breach_is_named() {
  local dir="$TMP_ROOT/desc"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  local body="$TMP_ROOT/long-body.md"
  : > "$body"
  local i
  for i in $(seq 1 40); do printf 'padding padding padding\n' >> "$body"; done
  run_check "$dir" --base main --head feature --body "$body"
  expect_code 1 "$RC" "a description over the length limit must exit non-zero"
  assert_contains "$OUT" "FAIL  description-max-length" "the description-length breach must be named"
  assert_contains "$OUT" "limit 200" "the description-length breach must show the configured limit"
  pass "fm-anti-slop-check: a description-length breach is named"
}

test_empty_description_breach_is_named() {
  local dir="$TMP_ROOT/empty-desc"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf '   \n\n\t\n' > "$TMP_ROOT/blank-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/blank-body.md"
  expect_code 1 "$RC" "a whitespace-only description must exit non-zero"
  assert_contains "$OUT" "FAIL  description-empty" "an empty description must be named as a breach"
  pass "fm-anti-slop-check: an empty description is named"
}

test_emoji_breach_is_named() {
  local dir="$TMP_ROOT/emoji"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'Ship it \360\237\232\200 and again \360\237\216\211 and once more \342\234\250\n' > "$TMP_ROOT/emoji-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/emoji-body.md"
  expect_code 1 "$RC" "a description over the emoji limit must exit non-zero"
  assert_contains "$OUT" "FAIL  emoji-count" "the emoji breach must be named"
  assert_contains "$OUT" "3 emoji, limit 1" "the emoji breach must show the count and the limit"
  pass "fm-anti-slop-check: an emoji breach is named"
}

# The real check counts the title too, so a title-only breach must be caught
# when the title is supplied, and the omission must be visible when it is not.
test_emoji_counts_the_title_when_given() {
  local dir="$TMP_ROOT/emoji-title"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'A plain description with no pictures at all.\n' > "$TMP_ROOT/plain-body.md"

  run_check "$dir" --base main --head feature --body "$TMP_ROOT/plain-body.md" \
    --title "$(printf 'fix: \360\237\232\200 \360\237\216\211 \342\234\250 ship')"
  expect_code 1 "$RC" "emoji in the title alone must breach the emoji limit"
  assert_contains "$OUT" "FAIL  emoji-count" "a title-only emoji breach must be named"

  run_check "$dir" --base main --head feature --body "$TMP_ROOT/plain-body.md"
  expect_code 0 "$RC" "without a title the body alone is measured"
  assert_contains "$OUT" "title not measured" "omitting the title must be stated on the emoji line, not hidden"
  pass "fm-anti-slop-check: the emoji rule counts the title, and says so when it has none"
}

test_blocked_term_breach_is_named() {
  local dir="$TMP_ROOT/terms"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'This body uses forbiddenword in plain sight.\n' > "$TMP_ROOT/term-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/term-body.md"
  expect_code 1 "$RC" "a blocked term in the description must exit non-zero"
  assert_contains "$OUT" "FAIL  blocked-terms" "the blocked-term breach must be named"
  assert_contains "$OUT" "forbiddenword" "the breach must name the term that was found"
  assert_not_contains "$OUT" "other-banned-phrase" "a configured term that is absent must not be reported as found"
  pass "fm-anti-slop-check: a blocked term is named"
}

# The real check strips HTML comments before searching, so a term that only
# appears inside a comment is not a breach. Getting this wrong would make the
# script reject bodies the forge would accept.
test_blocked_term_inside_an_html_comment_is_not_a_breach() {
  local dir="$TMP_ROOT/terms-comment"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'Visible text only.\n<!-- forbiddenword lives here -->\n' > "$TMP_ROOT/comment-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/comment-body.md"
  expect_code 0 "$RC" "a blocked term inside an HTML comment must not fail the run"
  assert_contains "$OUT" "PASS  blocked-terms" "a term hidden in a comment must be reported as absent"
  pass "fm-anti-slop-check: a blocked term inside an HTML comment is not a breach"
}

test_code_reference_breach_is_named() {
  local dir="$TMP_ROOT/coderefs"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" work
  printf 'Touches src/one.ts and src/two.ts and lib/three.ts, then calls doThing().\n' > "$TMP_ROOT/refs-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/refs-body.md"
  expect_code 1 "$RC" "a description over the code-reference limit must exit non-zero"
  assert_contains "$OUT" "FAIL  code-references" "the code-reference breach must be named"
  assert_contains "$OUT" "4 references, limit 2" "the code-reference breach must show the count and the limit"
  pass "fm-anti-slop-check: a code-reference breach is named"
}

test_blocked_path_breach_is_named() {
  local dir="$TMP_ROOT/paths"
  make_repo "$dir"
  printf 'edited\n' > "$dir/LICENSE"
  commit_all "$dir" work
  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "changing a blocked path must exit non-zero"
  assert_contains "$OUT" "FAIL  blocked-paths" "the blocked-path breach must be named"
  assert_contains "$OUT" "LICENSE" "the breach must name the file that was changed"
  pass "fm-anti-slop-check: a blocked-path breach is named"
}

# A file matching more than one blocked pattern is still one blocked file.
test_blocked_path_matching_two_patterns_counts_once() {
  local dir="$TMP_ROOT/paths-dup"
  make_repo "$dir"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@57858eead489d08b255fab2af45a506c2ca6eab2 # v0.3.0
        with:
          blocked-paths: |
            LICENSE
            license
YAML
  printf 'edited\n' > "$dir/LICENSE"
  commit_all "$dir" work
  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a blocked path must still fail"
  assert_contains "$OUT" "1 changed files in blocked paths" \
    "a file matching two blocked patterns must be counted once"
  pass "fm-anti-slop-check: a file matching two blocked patterns counts once"
}

# --- several breaches are reported together ---------------------------------

test_all_breaches_are_reported_in_one_run() {
  local dir="$TMP_ROOT/many"
  make_repo "$dir"
  seq 1 80 > "$dir/file.txt"
  local i
  for i in 1 2 3 4 5; do printf 'x\n' > "$dir/new$i.txt"; done
  printf 'edited\n' > "$dir/LICENSE"
  commit_all "$dir" work
  local body="$TMP_ROOT/many-body.md"
  {
    printf 'Reworks src/one.ts and src/two.ts and lib/three.ts and calls doThing().\n'
    printf 'It also says forbiddenword and other-banned-phrase out loud \360\237\232\200 \360\237\216\211 \342\234\250.\n'
    for i in $(seq 1 40); do printf 'padding padding padding\n'; done
  } > "$body"

  run_check "$dir" --base main --head feature --body "$body" --title t
  expect_code 1 "$RC" "a run with several breaches must exit non-zero"

  local rule
  for rule in max-changed-files max-changed-lines description-max-length emoji-count blocked-terms code-references blocked-paths; do
    assert_contains "$OUT" "FAIL  $rule" "one run must name the $rule breach rather than stopping at the first"
  done
  assert_contains "$OUT" "7 rule(s) breached" "the summary must count every breach found"
  pass "fm-anti-slop-check: every simultaneous breach is named in one run"
}

# --- not applicable ---------------------------------------------------------

test_project_without_the_check_is_not_applicable() {
  local dir="$TMP_ROOT/nocheck"
  mkdir -p "$dir/.github/workflows"
  git -C "$dir" init -q 2>/dev/null || { mkdir -p "$dir"; git -C "$dir" init -q; }
  cat > "$dir/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
  printf 'x\n' > "$dir/f.txt"
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base

  run_check "$dir" --base HEAD --head HEAD
  expect_code 0 "$RC" "a project with no such check must exit successfully"
  assert_contains "$OUT" "not applicable" "a project with no such check must say so"
  assert_not_contains "$OUT" "FAIL" "a project with no such check must report no breach"
  pass "fm-anti-slop-check: a project with no such check is reported as not applicable"
}

test_project_with_no_workflows_at_all_is_not_applicable() {
  local dir="$TMP_ROOT/bare"
  mkdir -p "$dir"
  run_check "$dir" --body "$TMP_ROOT/clean-body.md"
  expect_code 0 "$RC" "a project with no workflow directory must exit successfully"
  assert_contains "$OUT" "not applicable" "a project with no workflow directory must say so"
  pass "fm-anti-slop-check: a project with no workflows at all is not applicable"
}

# --- malformed configuration fails closed -----------------------------------

# The whole point of the script is that a false pass costs a rejected PR, so a
# configuration it cannot read must never be reported as a pass.
test_unparseable_limit_fails_closed() {
  local dir="$TMP_ROOT/badlimit"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@v0.3.0
        with:
          max-description-length: lots
YAML
  printf 'body\n' > "$TMP_ROOT/badlimit-body.md"
  run_check "$dir" --body "$TMP_ROOT/badlimit-body.md"
  expect_code 2 "$RC" "a limit that is not a number must fail closed, not pass"
  assert_contains "$OUT" "max-description-length" "the refusal must name the input it could not read"
  assert_not_contains "$OUT" "PASSED" "an unreadable configuration must never be reported as a pass"
  pass "fm-anti-slop-check: an unparseable limit fails closed"
}

test_unparseable_workflow_body_fails_closed() {
  local dir="$TMP_ROOT/badyaml"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@v0.3.0
        with:
          this line is not a mapping at all
YAML
  printf 'body\n' > "$TMP_ROOT/badyaml-body.md"
  run_check "$dir" --body "$TMP_ROOT/badyaml-body.md"
  expect_code 2 "$RC" "a with-block that cannot be parsed must fail closed"
  assert_not_contains "$OUT" "PASSED" "an unparseable workflow must never be reported as a pass"
  pass "fm-anti-slop-check: an unparseable workflow fails closed"
}

test_template_expression_limit_fails_closed() {
  local dir="$TMP_ROOT/expr"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@v0.3.0
        with:
          max-changed-lines: ${{ vars.MAX_LINES }}
YAML
  run_check "$dir" --base HEAD
  expect_code 2 "$RC" "a limit this script cannot evaluate must fail closed"
  assert_contains "$OUT" "max-changed-lines" "the refusal must name the input it could not evaluate"
  pass "fm-anti-slop-check: a limit given as a template expression fails closed"
}

test_two_anti_slop_steps_fail_closed() {
  local dir="$TMP_ROOT/twosteps"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@v0.3.0
        with:
          max-changed-lines: 100
      - uses: peakoss/anti-slop@v0.3.0
        with:
          max-changed-lines: 900
YAML
  run_check "$dir" --base HEAD
  expect_code 2 "$RC" "limits that could disagree must fail closed rather than picking one"
  assert_not_contains "$OUT" "PASSED" "an ambiguous configuration must never be reported as a pass"
  pass "fm-anti-slop-check: more than one configured step fails closed"
}

# --- limits come from the project, not from the script ----------------------

test_limits_are_read_from_the_project() {
  local dir="$TMP_ROOT/ownlimits"
  make_repo "$dir"
  # Replace the fixture's limits with a different, equally arbitrary set. The
  # same branch and body must now be judged against these numbers.
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@57858eead489d08b255fab2af45a506c2ca6eab2 # v0.3.0
        with:
          max-changed-lines: 7777
          max-emoji-count: 9
          max-description-length: 12345
YAML
  commit_all "$dir" work
  printf 'A body \360\237\232\200 with a couple of pictures \360\237\216\211 in it.\n' > "$TMP_ROOT/own-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/own-body.md" --title t
  expect_code 0 "$RC" "limits raised by the project must be honored"
  assert_contains "$OUT" "limit 7777" "the changed-line limit must come from the project's own workflow"
  assert_contains "$OUT" "limit 9" "the emoji limit must come from the project's own workflow"
  assert_contains "$OUT" "limit 12345" "the description limit must come from the project's own workflow"
  pass "fm-anti-slop-check: limits are read from the project rather than hardcoded"
}

# An input the project leaves unset falls back to the action's own default, and
# the output says which values came from where so a reader is not misled.
test_unset_inputs_fall_back_to_action_defaults() {
  local dir="$TMP_ROOT/defaults"
  make_repo "$dir"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@57858eead489d08b255fab2af45a506c2ca6eab2 # v0.3.0
        with:
          max-changed-lines: 5000
YAML
  commit_all "$dir" work
  printf 'Short body.\n' > "$TMP_ROOT/defaults-body.md"
  run_check "$dir" --base main --head feature --body "$TMP_ROOT/defaults-body.md" --title t
  expect_code 0 "$RC" "the defaults fixture must pass"
  assert_contains "$OUT" "chars, limit 2500 (action default)" "an unset description limit must use the action default and be labeled as such"
  assert_contains "$OUT" "lines, limit 5000" "a limit the project sets must not be labeled a default"
  assert_not_contains "$OUT" "lines, limit 5000 (action default)" "a limit the project sets must not be labeled a default"
  pass "fm-anti-slop-check: unset inputs fall back to labeled action defaults"
}

test_uncalibrated_version_warns_but_still_measures() {
  local dir="$TMP_ROOT/newversion"
  make_repo "$dir"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
jobs:
  anti-slop:
    steps:
      - uses: peakoss/anti-slop@v9.9.9
        with:
          max-changed-lines: 5000
YAML
  commit_all "$dir" work
  run_check "$dir" --base main --head feature
  expect_code 0 "$RC" "an unfamiliar version must still be measured"
  assert_contains "$OUT" "warning:" "an unfamiliar version must be called out"
  assert_contains "$OUT" "v9.9.9" "the warning must name the version the project pins"
  assert_contains "$OUT" "PASS  max-changed-lines" "an unfamiliar version must not stop the measurement"
  pass "fm-anti-slop-check: an unfamiliar action version warns but still measures"
}

# --- unmeasurable rules are visible, never silently passed ------------------

test_missing_inputs_are_reported_as_unmeasured() {
  local dir="$TMP_ROOT/partial"
  make_repo "$dir"
  seq 1 80 > "$dir/file.txt"
  commit_all "$dir" work
  printf 'A short clean body.\n' > "$TMP_ROOT/partial-body.md"

  run_check "$dir" --body "$TMP_ROOT/partial-body.md" --title t
  expect_code 0 "$RC" "body-only mode must not fail on rules it cannot measure"
  assert_contains "$OUT" "SKIP  max-changed-lines" "a rule with no input must be reported as unmeasured"
  assert_contains "$OUT" "pass --base" "an unmeasured rule must say what input it needs"

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "branch-only mode must still judge the branch rules"
  assert_contains "$OUT" "SKIP  description-max-length" "a body rule with no body must be reported as unmeasured"
  assert_contains "$OUT" "pass --body" "an unmeasured body rule must say what input it needs"
  pass "fm-anti-slop-check: a rule it cannot measure is reported, never treated as passing"
}

test_usage_errors_are_refused() {
  local dir="$TMP_ROOT/usage"
  make_repo "$dir"

  OUT=$("$CHECK" --project "$dir" 2>&1); RC=$?
  expect_code 2 "$RC" "a run with nothing to measure must be refused"
  assert_contains "$OUT" "nothing to measure" "the refusal must say what is missing"

  OUT=$("$CHECK" --project "$TMP_ROOT/does-not-exist" --base main 2>&1); RC=$?
  expect_code 2 "$RC" "an unresolvable project directory must be refused"

  OUT=$("$CHECK" --project "$dir" --base no-such-ref --head feature 2>&1); RC=$?
  expect_code 2 "$RC" "a base ref that does not resolve must be refused"
  assert_contains "$OUT" "no-such-ref" "the refusal must name the ref that did not resolve"

  OUT=$("$CHECK" --project "$dir" --body "$TMP_ROOT/no-such-body.md" 2>&1); RC=$?
  expect_code 2 "$RC" "a body file that does not exist must be refused"
  pass "fm-anti-slop-check: bad usage is refused rather than measured around"
}

# --- the limits interface other scripts read --------------------------------

test_print_limits_is_machine_readable() {
  local dir="$TMP_ROOT/printlimits"
  make_repo "$dir"

  OUT=$("$CHECK" --project "$dir" --print-limits 2>&1); RC=$?
  expect_code 0 "$RC" "printing limits must succeed"
  assert_contains "$OUT" "applicable=yes" "the limits output must state applicability"
  assert_contains "$OUT" "max_changed_lines=40" "the limits output must carry each configured limit"
  assert_contains "$OUT" "blocked_term=forbiddenword" "the limits output must carry each blocked term on its own line"
  assert_contains "$OUT" "blocked_path=LICENSE" "the limits output must carry each blocked path on its own line"

  OUT=$("$CHECK" --project "$TMP_ROOT/bare" --print-limits 2>&1); RC=$?
  expect_code 0 "$RC" "printing limits for a project without the check must succeed"
  assert_contains "$OUT" "applicable=no" "a project without the check must report itself as not applicable"
  pass "fm-anti-slop-check: --print-limits is machine readable for both outcomes"
}

test_help_includes_entire_header() {
  local out
  out=$("$CHECK" --help 2>&1)
  assert_contains "$out" "WHERE IT DELIBERATELY ERRS STRICT" "--help must carry the strictness caveats"
  assert_contains "$out" "WHAT IT DOES NOT MEASURE" "--help must carry the coverage limits"
  assert_contains "$out" "UTF-16" "--help must document how the description is counted"
  pass "fm-anti-slop-check: --help documents what it approximates"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-anti-slop-check.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-anti-slop-check.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-anti-slop-check.sh emitted unexpected output: $out"
  pass "fm-anti-slop-check: bash -n succeeds"
}

# The commit-message rule is the gap that let PR 1139 through: the local run
# reported a pass it could not support, and the forge failed the branch at 535
# characters against a 500 limit.
test_commit_message_length_breach_is_named() {
  local dir="$TMP_ROOT/commit-msg"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  git -C "$dir" add -A
  printf 'feat: a subject\n\n%s\n' "$(printf 'x%.0s' $(seq 1 200))" |
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -F -

  run_check "$dir" --base main --head feature
  expect_code 1 "$RC" "a commit message over the limit must fail the branch"
  assert_contains "$OUT" "FAIL  max-commit-message-length" "the breached rule must be named"
  assert_contains "$OUT" "over 60 chars" "the configured limit must be stated"
  pass "fm-anti-slop-check: an oversized commit message is named as a breach"
}

# The boundary is strictly greater than, matching the action's own comparison.
test_commit_message_at_the_limit_passes() {
  local dir="$TMP_ROOT/commit-msg-boundary"
  make_repo "$dir"
  printf 'two\n' >> "$dir/file.txt"
  git -C "$dir" add -A
  printf '%s' "$(printf 'y%.0s' $(seq 1 60))" |
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -F -

  run_check "$dir" --base main --head feature
  assert_contains "$OUT" "PASS  max-commit-message-length" "a message exactly at the limit must pass"
  assert_contains "$OUT" "0 of 1 commit messages" "the measured commit count must be stated"
  pass "fm-anti-slop-check: a commit message exactly at the limit passes"
}

# Only the commits this branch adds are measured, the way the action drops the
# commits a pull request inherits from the default branch.
test_base_branch_commit_messages_are_not_measured() {
  local dir="$TMP_ROOT/commit-msg-scope"
  make_repo "$dir"
  git -C "$dir" checkout -q main
  printf 'main\n' >> "$dir/file.txt"
  git -C "$dir" add -A
  printf 'chore: already on main\n\n%s\n' "$(printf 'z%.0s' $(seq 1 200))" |
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -F -
  git -C "$dir" checkout -q feature
  printf 'two\n' >> "$dir/file.txt"
  commit_all "$dir" "feat: short"

  run_check "$dir" --base main --head feature
  assert_contains "$OUT" "PASS  max-commit-message-length" "a long message already on the base branch is not this branch's breach"
  pass "fm-anti-slop-check: only the commits this branch adds are measured"
}

test_commit_message_rule_is_skipped_without_a_base() {
  local dir="$TMP_ROOT/commit-msg-nobase"
  make_repo "$dir"
  printf 'A short description.\n' > "$TMP_ROOT/commit-msg-nobase-body.md"

  run_check "$dir" --body "$TMP_ROOT/commit-msg-nobase-body.md" --title t
  assert_contains "$OUT" "SKIP  max-commit-message-length" "without a base ref the rule must report as unmeasured, never as passing"
  pass "fm-anti-slop-check: the commit-message rule is skipped, not assumed, without a base ref"
}

test_commit_message_limit_of_zero_disables_the_rule() {
  local dir="$TMP_ROOT/commit-msg-zero"
  make_repo "$dir"
  mkdir -p "$dir/.github/workflows"
  cat > "$dir/.github/workflows/anti-slop.yaml" <<'YAML'
name: Anti Slop
on: [pull_request]
jobs:
  anti-slop:
    runs-on: ubuntu-latest
    steps:
      - id: anti-slop
        uses: peakoss/anti-slop@57858eead489d08b255fab2af45a506c2ca6eab2 # v0.3.0
        with:
          max-commit-message-length: 0
YAML
  printf 'two\n' >> "$dir/file.txt"
  git -C "$dir" add -A
  printf 'feat: a subject\n\n%s\n' "$(printf 'x%.0s' $(seq 1 900))" |
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -F -

  run_check "$dir" --base main --head feature
  assert_not_contains "$OUT" "max-commit-message-length" "a limit of 0 disables the rule upstream, so it must not be reported at all"
  pass "fm-anti-slop-check: a commit-message limit of 0 disables the rule"
}

test_script_parses
test_help_includes_entire_header
test_clean_branch_and_body_pass
test_every_rule_reports_measurement_and_limit
test_changed_lines_breach_is_named
test_changed_files_breach_is_named
test_description_length_breach_is_named
test_empty_description_breach_is_named
test_emoji_breach_is_named
test_emoji_counts_the_title_when_given
test_blocked_term_breach_is_named
test_blocked_term_inside_an_html_comment_is_not_a_breach
test_code_reference_breach_is_named
test_blocked_path_breach_is_named
test_blocked_path_matching_two_patterns_counts_once
test_all_breaches_are_reported_in_one_run
test_project_without_the_check_is_not_applicable
test_project_with_no_workflows_at_all_is_not_applicable
test_unparseable_limit_fails_closed
test_unparseable_workflow_body_fails_closed
test_template_expression_limit_fails_closed
test_two_anti_slop_steps_fail_closed
test_limits_are_read_from_the_project
test_unset_inputs_fall_back_to_action_defaults
test_uncalibrated_version_warns_but_still_measures
test_missing_inputs_are_reported_as_unmeasured
test_usage_errors_are_refused
test_print_limits_is_machine_readable
test_commit_message_length_breach_is_named
test_commit_message_at_the_limit_passes
test_base_branch_commit_messages_are_not_measured
test_commit_message_rule_is_skipped_without_a_base
test_commit_message_limit_of_zero_disables_the_rule
