#!/usr/bin/env bash
# fm-auto-learn.sh - file one automatic learning into the captain's log.
#
# Usage: fm-auto-learn.sh <state-dir> <task> <source> <key> <fact> [<correction>]
#
# The only source is `learned`: a worker's deliberate `learned [at=<epoch>]: <fact>`
# line, seen by fm-classify-lib.sh, never an agent calling this script directly.
#
# <key> identifies the correction; the note is learnings/auto-<source>-<hash of
# source and key>.md, filed through `fm-log.sh learn --auto`, so the same
# correction never files twice and the note carries origin: auto for /stow.
# Its sources are --task <task> plus --project <basename of the task's project=>
# from <state-dir>/<task>.meta when present. <fact> becomes the title and, with
# <correction>, the body; each is whitespace-collapsed and bounded to
# FM_AUTO_LEARN_MAX_CHARS (default 400) characters so a learning holds the fact
# and its correction, never a transcript.
#
# Best effort by design: it prints nothing and always exits 0, so a caller's own
# work never depends on it. Nothing is filed when the log is off (fm-log.sh exits
# 3) or FM_AUTO_LEARN=off.
set -u

[ "${FM_AUTO_LEARN:-on}" != off ] || exit 0
[ "$#" -ge 5 ] && [ "$#" -le 6 ] || exit 0
state=$1 task=$2 source=$3 key=$4 fact=$5 correction=${6:-}
case "$source" in learned) ;; *) exit 0 ;; esac
case "$task" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -d "$state" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max=${FM_AUTO_LEARN_MAX_CHARS:-400}
case "$max" in ''|*[!0-9]*) max=400 ;; esac

bound() {  # <text>
  local t
  t=$(printf '%s' "$1" | tr '\n\t\r' '   ' | tr -s ' ')
  t=${t# }; t=${t% }
  [ "${#t}" -le "$max" ] || t="${t:0:$max}..."
  printf '%s' "$t"
}

fact=$(bound "$fact")
[ -n "$fact" ] || exit 0
correction=$(bound "$correction")
hash=$(printf '%s\0%s' "$source" "$key" | shasum -a 1 2>/dev/null | cut -c1-12)
[ -n "$hash" ] || exit 0
slug="auto-$source-$hash"

args=(--task "$task")
project=''
[ ! -f "$state/$task.meta" ] || project=$(sed -n 's/^project=//p' "$state/$task.meta" 2>/dev/null | tail -n 1)
project=${project%/}
[ -z "$project" ] || args+=(--project "${project##*/}")

body="$fact"$'\n'
[ -z "$correction" ] || body+=$'\n'"Corrected by: $correction"$'\n'
body+=$'\n'"Filed automatically ($source, task $task)."$'\n'

printf '%s' "$body" | FM_HOME="${FM_HOME:-$(dirname "$state")}" FM_STATE_OVERRIDE="$state" \
  "$SCRIPT_DIR/fm-log.sh" learn "$slug" "$fact" "${args[@]}" --auto >/dev/null 2>&1 || true
exit 0
