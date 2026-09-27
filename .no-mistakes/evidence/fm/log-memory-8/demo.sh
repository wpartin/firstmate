#!/usr/bin/env bash
# tests/fm-log-prompt-hook.test.sh - the Claude prompt hook that hands firstmate
# captain's log history (bin/fm-log-prompt-hook.sh, fm-log.sh recall --mentions):
# a prompt naming a configured ticket, a task id, or a person alias injects a
# pack; a prompt naming none injects nothing; the log off, an unbuilt index, a
# failing or slow recall, fleet machinery, and a crewmate worktree inject
# nothing and exit 0. bin/fm-log-prompt-hook.sh's header owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "/Users/wpartin/.no-mistakes/worktrees/c3110707bde4/01M3JEA3DYG3YW1E9B6V6D2VCY/tests/lib.sh"

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

H=$(make_home demo)
for p in "What happened with ENG-12?" "How is Dana doing?" "status of eng-12-retry" "what's the weather like"; do
  echo "=== prompt: $p"; out=$(hook "$H" "$p"); if [ -z "$out" ]; then echo "(no output - nothing injected)"; else printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext; fi
done
