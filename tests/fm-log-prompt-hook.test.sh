#!/usr/bin/env bash
# tests/fm-log-prompt-hook.test.sh - the harness-agnostic prompt hook that hands firstmate
# captain's log history (bin/fm-log-prompt-hook.sh, fm-log.sh recall --mentions):
# a prompt naming a configured ticket, a task id, or a person alias injects a
# pack; a prompt naming none injects nothing; the log off, an unbuilt index, a
# failing or slow recall, fleet machinery, and a crewmate worktree inject
# nothing and exit 0. bin/fm-log-prompt-hook.sh's header owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-log-prompt-hook)
export TZ=UTC
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE CLAUDE_PROJECT_DIR

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY"
git init -q "$PRIMARY"
: > "$PRIMARY/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY/bin"

T0=1790240400

make_home() {  # <name>: prints a synced home whose log names ENG-12, task eng-12-retry, and Dana Reyes (alias Dana)
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'on\n' > "$home/config/log"
  : > "$home/config/fleet-ledger"
  printf '(?i)\\b(ENG-[0-9]+)\\b\thttps://tracker.example/{id}\n' > "$home/config/log-tickets"
  printf 'Dana Reyes\tDana\n' > "$home/config/log-people"
  cat > "$home/snapshot.json" <<'EOF'
{"queue":[{"id":"eng-12-retry","title":"ENG-12 retry billing calls","repo":"billing","state":"in_flight","hold_bucket":null,"hold_kind":null,"blocked_by":[],"people":["Dana Reyes"]}],
 "in_flight":[{"id":"eng-12-retry","name":"ENG-12 retry billing calls","repo":"billing"}]}
EOF
  printf '%s\n' \
    '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"eng-12-retry","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":["ENG-12"],"people":["Dana Reyes"]}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"captain.held","task":"eng-12-retry","reason":"retry on 429 or back off?","until":null}' \
    '{"v":1,"ts":'"$((T0 + 120))"',"event":"captain.answered","task":"eng-12-retry","mode":"answered","source":null,"words":"retry with jitter, never approach B"}' \
    >> "$home/state/fleet-ledger.jsonl"
  hook_env "$home" "$ROOT/bin/fm-log.sh" sync >/dev/null 2>&1 || fail "fixture sync failed"
  printf '%s\n' "$home"
}

hook_env() {  # <home> <command...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_LOG_SNAPSHOT_FILE="$home/snapshot.json" FM_LOG_TODAY=2026-09-25 "$@"
}

hook() {  # <home> <prompt> [hook path]: the hook's stdout; fails the test on a nonzero exit
  local out rc
  out=$(jq -cn --arg p "$2" '{hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | hook_env "$1" "${3:-$PRIMARY/bin/fm-log-prompt-hook.sh}")
  rc=$?
  [ "$rc" -eq 0 ] || fail "hook exited $rc"
  printf '%s' "$out"
}

context() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

test_ticket_prompt_injects_pack() {
  local home out ctx
  home=$(make_home ticket)
  out=$(hook "$home" "what did we settle on eng-12?")
  assert_equals "UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "hook event"
  ctx=$(context "$out")
  assert_contains "$ctx" "resolved: ticket ENG-12" "pack"
  assert_contains "$ctx" "retry with jitter, never approach B" "pack"
  pass "a prompt naming a configured ticket id injects the recall pack"
}

test_task_and_alias_prompts_inject_pack() {
  local home
  home=$(make_home entities)
  assert_contains "$(context "$(hook "$home" "status of eng-12-retry please")")" "task eng-12-retry" "task pack"
  assert_contains "$(context "$(hook "$home" "Dana asked about retries")")" "person Dana Reyes" "alias pack"
  pass "a prompt naming a task id or a registered person alias injects the pack"
}

test_prompt_naming_nothing_injects_nothing() {
  local home
  home=$(make_home plain)
  assert_equals "" "$(hook "$home" "what did we decide about retries and billing?")" "hook output"
  assert_equals "" "$(hook "$home" "dana and eng-12retry are not exact")" "hook output"
  pass "a prompt with no exact ticket, task, or person injects nothing"
}

test_log_off_injects_nothing() {
  local home
  home=$(make_home off)
  printf 'off\n' > "$home/config/log"
  assert_equals "" "$(hook "$home" "ENG-12?")" "hook output"
  pass "the log off injects nothing"
}

test_failures_inject_nothing() {
  local home fakebin start
  home=$(make_home fail)
  rm -f "$home/state/.log-index.db"
  assert_equals "" "$(hook "$home" "ENG-12?")" "unbuilt index"
  home=$(make_home broken)
  printf 'not a database' > "$home/state/.log-index.db"
  assert_equals "" "$(hook "$home" "ENG-12?")" "corrupt index"
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cp "$ROOT"/bin/fm-log-prompt-hook.sh "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-timeout-lib.sh \
    "$ROOT"/bin/fm-operational-input.sh "$fakebin"/
  printf '#!/usr/bin/env bash\necho partial; exit 1\n' > "$fakebin/fm-log.sh"
  chmod +x "$fakebin/fm-log.sh"
  home=$(make_home exits)
  assert_equals "" "$(hook "$home" "ENG-12?" "$fakebin/fm-log-prompt-hook.sh")" "failing recall"
  printf '#!/usr/bin/env bash\nsleep 30; echo late\n' > "$fakebin/fm-log.sh"
  start=$(date +%s)
  assert_equals "" "$(FM_LOG_PROMPT_HOOK_TIMEOUT=1 hook "$home" "ENG-12?" "$fakebin/fm-log-prompt-hook.sh")" "slow recall"
  [ $(( $(date +%s) - start )) -lt 10 ] || fail "a slow recall held the prompt"
  pass "an unbuilt or corrupt index and a failing or slow recall inject nothing and exit 0"
}

test_machinery_and_worktrees_inject_nothing() {
  local home wt out
  home=$(make_home scope)
  assert_equals "" "$(hook "$home" "<task-notification>ENG-12 done</task-notification>")" "task notification"
  wt="$TMP_ROOT/worktree"
  git -C "$PRIMARY" commit -q --allow-empty -m init
  git -C "$PRIMARY" worktree add -q --detach "$wt"
  : > "$wt/AGENTS.md"
  ln -s "$ROOT/bin" "$wt/bin"
  out=$(jq -cn '{prompt:"ENG-12?"}' | FM_ROOT_OVERRIDE="$wt" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" "$wt/bin/fm-log-prompt-hook.sh")
  assert_equals "" "$out" "worktree hook output"
  pass "harness-started turns and a crewmate worktree inject nothing"
}

test_text_and_codex_modes_share_the_core() {
  local home out
  home=$(make_home modes)
  out=$(printf 'what did we settle on eng-12?' | hook_env "$home" "$PRIMARY/bin/fm-log-prompt-hook.sh" text)
  assert_contains "$out" "resolved: ticket ENG-12" "text pack"
  [ "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1; echo $?)" != 0 ] || fail "text mode printed JSON"
  assert_equals "" "$(printf 'nothing exact here' | hook_env "$home" "$PRIMARY/bin/fm-log-prompt-hook.sh" text)" "text naming nothing"
  assert_equals "" "$(printf '<task-notification>ENG-12</task-notification>' | hook_env "$home" "$PRIMARY/bin/fm-log-prompt-hook.sh" text)" "text machinery"
  out=$(jq -cn '{hook_event_name:"UserPromptSubmit",prompt:"ENG-12?"}' | hook_env "$home" "$PRIMARY/bin/fm-log-prompt-hook.sh" codex)
  assert_contains "$(context "$out")" "resolved: ticket ENG-12" "codex pack"
  assert_equals "" "$(printf 'ENG-12?' | hook_env "$home" "$PRIMARY/bin/fm-log-prompt-hook.sh" bogus)" "unknown mode"
  pass "text and codex modes print the same pack through the one core, and an unknown mode prints nothing"
}

test_every_wired_harness_registers_the_core() {
  local home payload cmd out
  home=$(make_home registered)
  payload=$(jq -cn '{hook_event_name:"UserPromptSubmit",prompt:"what did we settle on ENG-12?"}')
  mkdir -p "$PRIMARY/.codex"
  cp "$ROOT/.codex/hooks.json" "$PRIMARY/.codex/hooks.json"
  cmd=$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(contains("fm-log-prompt-hook.sh"))' "$ROOT/.claude/settings.json")
  out=$(cd "$PRIMARY" && printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PRIMARY" hook_env "$home" bash -c "$cmd")
  assert_contains "$(context "$out")" "resolved: ticket ENG-12" "Claude registered command"
  cmd=$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(contains("fm-log-prompt-hook.sh"))' "$ROOT/.codex/hooks.json")
  out=$(cd "$PRIMARY" && printf '%s' "$payload" | hook_env "$home" bash -c "$cmd")
  assert_contains "$(context "$out")" "resolved: ticket ENG-12" "Codex registered command"
  rm -rf "$PRIMARY/.codex"
  pass "the commands Claude and Codex register on their prompt-submit hook deliver the core's pack"
}

test_pi_and_omp_extensions_deliver_the_core() {
  local fixture ext out
  command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Pi and omp extension test"; return 0; }
  fixture="$TMP_ROOT/extensions"
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/.omp/extensions" "$fixture/bin" "$fixture/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$fixture/.pi/extensions/"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$fixture/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$fixture/.pi/extensions/lib/"
  # shellcheck disable=SC2016 # the stub script expands its own variables
  printf '#!/usr/bin/env bash\n[ "${1:-}" = text ] || exit 0\nmsg=$(cat)\ncase "$msg" in *ENG-12*) printf "RECALL for %%s\\n" "$msg" ;; esac\n' \
    > "$fixture/bin/fm-log-prompt-hook.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/fm-turnend-guard.sh"
  chmod +x "$fixture/bin/"*.sh
  for ext in .pi .omp; do
    out=$(EXT="$fixture/$ext/extensions/fm-primary-turnend-guard.ts" FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
      node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
const ctx = { sessionManager: { getEntries: () => [], getSessionId: () => "s" } };
const named = await handlers.get("before_agent_start")({ prompt: "what about ENG-12?" }, ctx);
const plain = await handlers.get("before_agent_start")({ prompt: "nothing exact" }, ctx);
console.log(JSON.stringify({ named, plain: plain ?? null }));
process.exit(0);
JS
)
    assert_equals "RECALL for what about ENG-12?" "$(printf '%s' "$out" | jq -r '.named.message.content')" "$ext recall"
    assert_equals "false" "$(printf '%s' "$out" | jq -r '.named.message.display')" "$ext display"
    assert_equals "null" "$(printf '%s' "$out" | jq -c '.plain')" "$ext naming nothing"
  done
  pass "the Pi and omp prompt handlers deliver the core's pack and add nothing when it prints nothing"
}

test_ticket_prompt_injects_pack
test_pi_and_omp_extensions_deliver_the_core
test_text_and_codex_modes_share_the_core
test_every_wired_harness_registers_the_core
test_task_and_alias_prompts_inject_pack
test_prompt_naming_nothing_injects_nothing
test_log_off_injects_nothing
test_failures_inject_nothing
test_machinery_and_worktrees_inject_nothing
