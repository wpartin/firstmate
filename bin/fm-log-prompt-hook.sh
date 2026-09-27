#!/usr/bin/env bash
# fm-log-prompt-hook.sh - hand firstmate the captain's log history for what the
# captain's message names exactly (docs/captains-log.md "Recall").
#
# Claude UserPromptSubmit hook, registered in .claude/settings.json. It reads the
# hook payload on stdin and, only when the submitted prompt names an exact
# configured ticket id, logged task id, or registered person or alias, prints
# `fm-log.sh recall --mentions <prompt> --for captain` wrapped as Claude
# hookSpecificOutput additionalContext, which Claude adds to the turn. Matching
# is exact only (bin/fm-log.sh "Recall"); anything fuzzier stays with the
# captains-log skill trigger.
#
# It prints nothing and exits 0 - so the prompt goes through untouched - when:
#   - the hook runs outside a genuine primary firstmate home (a crewmate
#     worktree shares this settings file), or jq or python3 is missing
#   - the prompt is fleet machinery (bin/fm-operational-input.sh classifies it)
#     or a harness-started <task-notification> turn
#   - the log is off, the index is missing, empty, or unreadable
#   - the prompt names nothing, or nothing it names has history
#   - recall fails or runs past FM_LOG_PROMPT_HOOK_TIMEOUT seconds (default 3)
#
# Claude only for now; other harnesses' prompt hooks are later work.
#
# Environment: FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE,
# FM_DATA_OVERRIDE as bin/fm-log.sh reads them.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOUND="${FM_LOG_PROMPT_HOOK_TIMEOUT:-3}"
case "$BOUND" in ''|0|*[!0-9]*) BOUND=3 ;; esac

command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -f "$STATE/.log-index.db" ] || exit 0

PROMPT=$(jq -r '(.prompt // "") | tostring' 2>/dev/null) || exit 0
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in '<task-notification>'*) exit 0 ;; esac
printf '%s' "$PROMPT" | "$SCRIPT_DIR/fm-operational-input.sh" classify >/dev/null 2>&1 && exit 0

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
PACK=$(FM_HOME="$FM_HOME" fm_run_timed "$BOUND" "$SCRIPT_DIR/fm-log.sh" recall --mentions "$PROMPT" --for captain 2>/dev/null) || exit 0
[ -n "$PACK" ] || exit 0
printf 'Captain'"'"'s log history for what this message names (fm-log.sh recall; cite it, verify volatile details):\n%s\n' "$PACK" \
  | jq -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}' 2>/dev/null || true
exit 0
