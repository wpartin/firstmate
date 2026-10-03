#!/usr/bin/env bash
# Live guard for the exact-mention captain's log history on every wired primary
# harness (bin/fm-log-prompt-hook.sh, docs/captains-log.md "Recall"): each
# INSTALLED harness runs one real headless prompt in a fixture primary whose
# log records a captain answer on ticket ENG-4242, and the model must quote
# words it can only have seen through the injected history. The wirings read
# vendor hook payloads and deliver through vendor context channels, so only
# the real harness can prove them. Opt-in because it submits prompts:
#
#   FM_LOG_PROMPT_HOOK_LIVE_E2E=1 tests/fm-log-prompt-hook-live-e2e.test.sh
#
# FM_LOG_PROMPT_HOOK_LIVE_HARNESSES (default "claude codex pi omp") narrows the
# set. An absent harness is reported, never passed over silently, and a run
# that checked no harness fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_LOG_PROMPT_HOOK_LIVE_E2E jq python3

HARNESSES=${FM_LOG_PROMPT_HOOK_LIVE_HARNESSES:-claude codex pi omp}
LAB=$(fm_test_tmproot fm-log-prompt-hook-live)
WORDS='kestrel-harbor-7'
PROMPT='What exact words did the captain answer on ENG-4242? Reply with only those words, or with the word unknown if nothing in your context says.'
T0=1790240400
CHECKED=0
ABSENT=
trap fm_test_cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE

# A primary checkout whose synced log names ENG-4242, carrying only this repo's prompt-hook registrations.
make_primary() {  # <name>
  local root="$LAB/$1"
  mkdir -p "$root/state" "$root/config" "$root/data" "$root/.claude" "$root/.codex"
  git init -q "$root"
  : > "$root/AGENTS.md"
  ln -s "$ROOT/bin" "$root/bin"
  printf 'on\n' > "$root/config/log"
  : > "$root/config/fleet-ledger"
  printf '(?i)\\b(ENG-[0-9]+)\\b\thttps://tracker.example/{id}\n' > "$root/config/log-tickets"
  printf '{"queue":[],"in_flight":[]}\n' > "$root/snapshot.json"
  printf '%s\n' \
    '{"v":1,"ts":'"$T0"',"event":"task.dispatched","task":"eng-4242-fix","kind":"ship","project":"billing","harness":"claude","model":null,"tickets":["ENG-4242"],"people":[]}' \
    '{"v":1,"ts":'"$((T0 + 60))"',"event":"captain.held","task":"eng-4242-fix","reason":"which marker?","until":null}' \
    '{"v":1,"ts":'"$((T0 + 120))"',"event":"captain.answered","task":"eng-4242-fix","mode":"answered","source":null,"words":"'"$WORDS"'"}' \
    > "$root/state/fleet-ledger.jsonl"
  FM_HOME="$root" FM_LOG_SNAPSHOT_FILE="$root/snapshot.json" "$root/bin/fm-log.sh" sync >/dev/null 2>&1 \
    || fail "fixture log sync failed"
  printf 'ENG-4242?' | FM_HOME="$root" "$root/bin/fm-log-prompt-hook.sh" text | grep -q "$WORDS" \
    || fail "fixture recall does not carry the answer; the core itself is broken"
  jq '{hooks: {UserPromptSubmit: [.hooks.UserPromptSubmit[] | .hooks |= map(select(.command | contains("fm-log-prompt-hook.sh")))]}}' \
    "$ROOT/.claude/settings.json" > "$root/.claude/settings.json"
  jq '{hooks: {UserPromptSubmit: .hooks.UserPromptSubmit}}' "$ROOT/.codex/hooks.json" > "$root/.codex/hooks.json"
  mkdir -p "$root/.pi" "$root/.omp"
  cp -R "$ROOT/.pi/extensions" "$root/.pi/"
  cp -R "$ROOT/.omp/extensions" "$root/.omp/"
  printf '%s\n' "$root"
}

run_harness() {  # <harness> <root>: prints the model's reply
  local harness=$1 root=$2
  case "$harness" in
    claude) (cd "$root" && claude -p "$PROMPT" --permission-mode dontAsk 2>&1) ;;
    codex) (cd "$root" && codex exec --skip-git-repo-check "$PROMPT" 2>&1) ;;
    pi) (cd "$root" && pi -p --no-session "$PROMPT" 2>&1) ;;
    omp) (cd "$root" && omp -p --no-session "$PROMPT" 2>&1) ;;
  esac
}

for harness in $HARNESSES; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'absent: %s is not installed; its prompt-hook wiring was not checked\n' "$harness"
    ABSENT="$ABSENT $harness"
    continue
  fi
  version=$("$harness" --version 2>/dev/null | head -1)
  root=$(make_primary "$harness")
  reply=$(run_harness "$harness" "$root")
  case "$reply" in
    *"$WORDS"*) pass "$harness $version: a prompt naming ENG-4242 received the captain's log history" ;;
    *) fail "$harness $version: the prompt-hook history never reached the model; reply: $(printf '%s' "$reply" | tail -5)" ;;
  esac
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail "no wired harness is installed (absent:$ABSENT); nothing was checked"
[ -z "$ABSENT" ] || printf 'absent harnesses not checked:%s\n' "$ABSENT"
